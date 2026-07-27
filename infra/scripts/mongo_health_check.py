#!/usr/bin/env python3
"""
One-shot MongoDB health and bottleneck scan for the quant stack.

Reads connection settings from (in order): --uri, MONGO_URI, apps/.env
DOCKER_MONGO_URI (host quant-mongodb rewritten to 127.0.0.1). Optionally
enriches with docker stats for container quant-mongodb.

Usage:
  ./infra/scripts/mongo_health_check.py
  ./infra/scripts/mongo_health_check.py --json
  ./infra/scripts/mongo-health.sh

Exit codes: 0 = OK, 1 = warnings, 2 = critical findings.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    from pymongo import MongoClient
    from pymongo.errors import PyMongoError
except ImportError:
    print("pymongo is required: pip install pymongo", file=sys.stderr)
    sys.exit(2)

INFRA_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = INFRA_ROOT.parent
APPS_ENV = REPO_ROOT / "apps" / ".env"
INFRA_ENV = INFRA_ROOT / ".env"

DEFAULT_CONTAINER = "quant-mongodb"

# Heuristic thresholds (tune in one place).
CONN_UTIL_WARN = 0.70
CONN_UTIL_CRIT = 0.90
WT_CACHE_UTIL_WARN = 0.85
WT_CACHE_UTIL_CRIT = 0.95
GLOBAL_LOCK_QUEUE_WARN = 1
DISK_UTIL_WARN_PCT = 85
DISK_UTIL_CRIT_PCT = 92
DOCKER_MEM_UTIL_WARN = 0.80
DOCKER_MEM_UTIL_CRIT = 0.92
LONG_OP_SEC_WARN = 5.0

QUEUE_SPECS: Tuple[Tuple[str, str, str], ...] = (
    ("quant_trading", "portfolio_research_jobs", "status"),
    ("finance", "backtest_tasks", "status"),
    ("finance", "pipeline_tasks", "status"),
    ("finance", "analysis_tasks", "status"),
)

SCAN_DATABASES: Tuple[str, ...] = (
    "finance",
    "quant_trading",
    "quant_data",
    "quant_analyzer",
    "quant_realtime",
    "admin",
)


@dataclass
class Finding:
    level: str  # info | warn | crit
    category: str
    message: str


@dataclass
class Report:
    generated_at: str
    uri_host: str
    findings: List[Finding] = field(default_factory=list)
    sections: Dict[str, Any] = field(default_factory=dict)

    def add(self, level: str, category: str, message: str) -> None:
        self.findings.append(Finding(level, category, message))

    def worst_exit_code(self) -> int:
        if any(f.level == "crit" for f in self.findings):
            return 2
        if any(f.level == "warn" for f in self.findings):
            return 1
        return 0


def _parse_env_file(path: Path) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        out[key.strip()] = val.strip().strip('"').strip("'")
    return out


def resolve_uri(explicit: Optional[str]) -> str:
    if explicit:
        return explicit.strip()
    env_uri = (os.getenv("MONGO_URI") or os.getenv("DOCKER_MONGO_URI") or "").strip()
    if env_uri:
        return _rewrite_docker_host(env_uri)
    merged = _parse_env_file(APPS_ENV)
    merged.update(_parse_env_file(INFRA_ENV))
    if merged.get("DOCKER_MONGO_URI"):
        return _rewrite_docker_host(merged["DOCKER_MONGO_URI"])
    user = merged.get("MONGO_USERNAME", "admin")
    password = merged.get("MONGO_PASSWORD", "")
    host = merged.get("MONGO_HOST", "127.0.0.1")
    port = merged.get("MONGO_PORT", "27017")
    if not password:
        raise SystemExit(
            "No Mongo URI found. Set MONGO_URI, apps/.env DOCKER_MONGO_URI, or infra/.env credentials."
        )
    auth = f"{user}:{password}"
    return f"mongodb://{auth}@{host}:{port}/?authSource=admin&maxPoolSize=20"


def _rewrite_docker_host(uri: str) -> str:
    return uri.replace("@quant-mongodb:", "@127.0.0.1:").replace("mongodb://quant-mongodb:", "mongodb://127.0.0.1:")


def _redact_uri(uri: str) -> str:
    return re.sub(r"://([^:@/]+):([^@/]+)@", r"://\1:***@", uri)


def _uri_host(uri: str) -> str:
    m = re.search(r"@([^/?]+)", uri)
    return m.group(1) if m else "unknown"


def _run_docker(args: List[str]) -> Optional[str]:
    try:
        proc = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def docker_container_stats(container: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {"container": container, "present": False}
    inspect = _run_docker(
        [
            "docker",
            "inspect",
            container,
            "--format",
            "{{.State.Status}}|{{.State.OOMKilled}}|{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}",
        ]
    )
    if not inspect:
        return out
    status, oom, mem_limit, nano_cpus = inspect.split("|", 3)
    out["present"] = True
    out["status"] = status
    out["oom_killed"] = oom == "true"
    out["mem_limit_bytes"] = int(mem_limit) if mem_limit.isdigit() else None
    out["cpu_limit"] = int(nano_cpus) / 1e9 if nano_cpus.isdigit() else None

    stats = _run_docker(
        ["docker", "stats", container, "--no-stream", "--format", "{{.MemUsage}}|{{.MemPerc}}|{{.CPUPerc}}"]
    )
    if stats:
        mem_usage, mem_pct, cpu_pct = stats.split("|", 2)
        out["mem_usage"] = mem_usage.strip()
        out["mem_percent"] = mem_pct.strip().rstrip("%")
        out["cpu_percent"] = cpu_pct.strip().rstrip("%")

    df_line = _run_docker(["docker", "exec", container, "df", "-h", "/data/db"])
    if df_line:
        lines = [ln for ln in df_line.splitlines() if ln.startswith("/") or "Filesystem" in ln]
        out["data_db_df"] = lines[-1] if lines else df_line.splitlines()[-1]

    return out


def _mb_from_bytes(n: Optional[Any]) -> Optional[float]:
    if n is None:
        return None
    try:
        return round(int(n) / (1024 * 1024), 1)
    except (TypeError, ValueError):
        return None


def collect_server_status(client: MongoClient) -> Dict[str, Any]:
    admin = client.admin
    status = admin.command("serverStatus")
    conn = status.get("connections") or {}
    mem = status.get("mem") or {}
    wt = (status.get("wiredTiger") or {}).get("cache") or {}
    glob = status.get("globalLock") or {}
    cache_bytes = wt.get("bytes currently in the cache")
    cache_max = wt.get("maximum bytes configured")
    cache_util = None
    if cache_bytes is not None and cache_max:
        cache_util = int(cache_bytes) / int(cache_max)

    current = conn.get("current")
    available = conn.get("available")
    conn_denom = (current or 0) + (available or 0)
    conn_util = (current / conn_denom) if conn_denom else None

    return {
        "version": status.get("version"),
        "uptime_hours": round(status.get("uptime", 0) / 3600, 2),
        "connections": {
            "current": current,
            "available": available,
            "active": conn.get("active"),
            "rejected": conn.get("rejected"),
            "total_created": conn.get("totalCreated"),
            "utilization": round(conn_util, 4) if conn_util is not None else None,
        },
        "memory": {
            "resident_mb": mem.get("resident"),
            "virtual_mb": mem.get("virtual"),
        },
        "wired_tiger_cache": {
            "used_mb": _mb_from_bytes(cache_bytes),
            "max_mb": _mb_from_bytes(cache_max),
            "utilization": round(cache_util, 4) if cache_util is not None else None,
        },
        "opcounters": {k: int(v) for k, v in (status.get("opcounters") or {}).items()},
        "global_lock": {
            "current_queue": glob.get("currentQueue"),
            "active_clients": glob.get("activeClients"),
        },
        "network": {
            "bytes_in_mb": _mb_from_bytes(status.get("network", {}).get("bytesIn")),
            "bytes_out_mb": _mb_from_bytes(status.get("network", {}).get("bytesOut")),
        },
    }


def collect_current_ops(client: MongoClient) -> Dict[str, Any]:
    admin = client.admin
    raw = admin.command({"currentOp": 1, "$all": True})
    inprog = raw.get("inprog") or []
    long_ops: List[Dict[str, Any]] = []
    by_ns: Counter[str] = Counter()
    for op in inprog:
        if op.get("op") in (None, "none", "idleSession"):
            continue
        ns = op.get("ns") or "?"
        # Long-lived mongosh / driver metadata commands are not workload.
        if ns.startswith("admin.$cmd") and op.get("op") == "command":
            continue
        by_ns[ns] += 1
        secs = op.get("secs_running") or op.get("microsecs_running", 0) / 1_000_000
        if secs and float(secs) >= LONG_OP_SEC_WARN:
            long_ops.append(
                {
                    "ns": ns,
                    "op": op.get("op"),
                    "secs_running": round(float(secs), 2),
                    "desc": op.get("desc"),
                }
            )
    return {
        "active_non_idle": sum(by_ns.values()),
        "ops_by_ns": dict(by_ns),
        "long_running_ops": sorted(long_ops, key=lambda x: -x["secs_running"])[:15],
    }


def collect_db_stats(client: MongoClient) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for name in SCAN_DATABASES:
        try:
            stats = client[name].command("dbStats", scale=1024 * 1024)
        except PyMongoError:
            continue
        rows.append(
            {
                "db": name,
                "data_mb": round(stats.get("dataSize", 0), 2),
                "storage_mb": round(stats.get("storageSize", 0), 2),
                "index_mb": round(stats.get("indexSize", 0), 2),
                "collections": stats.get("collections"),
                "objects": stats.get("objects"),
            }
        )
    rows.sort(key=lambda r: r.get("storage_mb", 0), reverse=True)
    return rows


def collect_top_collections(client: MongoClient, limit: int = 15) -> List[Dict[str, Any]]:
    ranked: List[Dict[str, Any]] = []
    for db_name in SCAN_DATABASES:
        try:
            cursor = client[db_name].aggregate([{"$collStats": {}}], allowDiskUse=True)
        except PyMongoError:
            continue
        for st in cursor:
            coll = st.get("ns", "").split(".", 1)[-1]
            if coll.startswith("system."):
                continue
            ranked.append(
                {
                    "ns": st.get("ns") or f"{db_name}.{coll}",
                    "storage_mb": round(st.get("storageSize", 0) / (1024 * 1024), 2),
                    "count": st.get("count"),
                    "avg_doc_bytes": st.get("avgObjSize"),
                }
            )
    ranked.sort(key=lambda r: r["storage_mb"], reverse=True)
    return ranked[:limit]


def collect_queue_depths(client: MongoClient) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for db_name, coll_name, status_field in QUEUE_SPECS:
        try:
            col = client[db_name][coll_name]
            if coll_name not in client[db_name].list_collection_names():
                rows.append({"ns": f"{db_name}.{coll_name}", "missing": True})
                continue
            counts = Counter(doc.get(status_field) for doc in col.find({}, {status_field: 1}))
            pending = counts.get("pending", 0)
            running = counts.get("running", 0) + counts.get("processing", 0)
            failed = counts.get("failed", 0) + counts.get("error", 0)
            rows.append(
                {
                    "ns": f"{db_name}.{coll_name}",
                    "status_counts": dict(counts),
                    "pending": pending,
                    "running": running,
                    "failed": failed,
                    "backlog": pending + running,
                }
            )
        except PyMongoError as exc:
            rows.append({"ns": f"{db_name}.{coll_name}", "error": str(exc)})
    return rows


def apply_heuristics(report: Report, docker: Dict[str, Any]) -> None:
    ss = report.sections.get("server_status") or {}
    conn = ss.get("connections") or {}
    util = conn.get("utilization")
    if util is not None:
        if util >= CONN_UTIL_CRIT:
            report.add("crit", "connections", f"Connection pool utilization {util:.0%} (>= {CONN_UTIL_CRIT:.0%})")
        elif util >= CONN_UTIL_WARN:
            report.add("warn", "connections", f"Connection pool utilization {util:.0%} (>= {CONN_UTIL_WARN:.0%})")

    if conn.get("rejected"):
        report.add("crit", "connections", f"Rejected connections: {conn.get('rejected')}")

    wt = ss.get("wired_tiger_cache") or {}
    cutil = wt.get("utilization")
    if cutil is not None:
        if cutil >= WT_CACHE_UTIL_CRIT:
            report.add("crit", "cache", f"WiredTiger cache {cutil:.0%} full (>= {WT_CACHE_UTIL_CRIT:.0%})")
        elif cutil >= WT_CACHE_UTIL_WARN:
            report.add("warn", "cache", f"WiredTiger cache {cutil:.0%} (>= {WT_CACHE_UTIL_WARN:.0%})")

    q = (ss.get("global_lock") or {}).get("current_queue") or {}
    total_q = (q.get("total") or 0) if isinstance(q, dict) else 0
    if total_q >= GLOBAL_LOCK_QUEUE_WARN:
        report.add("warn", "lock", f"Global lock queue depth {total_q}")

    for op in (report.sections.get("current_ops") or {}).get("long_running_ops") or []:
        report.add(
            "warn",
            "ops",
            f"Long op {op.get('secs_running')}s on {op.get('ns')} ({op.get('op')})",
        )

    if docker.get("present"):
        if docker.get("oom_killed"):
            report.add("crit", "docker", f"Container {docker.get('container')} was OOM-killed")
        mem_pct = docker.get("mem_percent")
        if mem_pct:
            try:
                mp = float(mem_pct)
                if mp >= DOCKER_MEM_UTIL_CRIT * 100:
                    report.add("crit", "docker", f"Container memory {mp:.1f}% of limit")
                elif mp >= DOCKER_MEM_UTIL_WARN * 100:
                    report.add("warn", "docker", f"Container memory {mp:.1f}% of limit")
            except ValueError:
                pass
        df_line = docker.get("data_db_df") or ""
        m = re.search(r"(\d+)%\s+/data/db", df_line)
        if not m:
            m = re.search(r"\s(\d{1,3})%\s+", df_line)
        if m:
            pct = int(m.group(1))
            if pct >= DISK_UTIL_CRIT_PCT:
                report.add("crit", "disk", f"/data/db filesystem {pct}% used")
            elif pct >= DISK_UTIL_WARN_PCT:
                report.add("warn", "disk", f"/data/db filesystem {pct}% used")

    for row in report.sections.get("queues") or []:
        backlog = row.get("backlog") or 0
        failed = row.get("failed") or 0
        ns = row.get("ns", "?")
        if backlog >= 50:
            report.add("warn", "queue", f"{ns} backlog (pending+running) = {backlog}")
        if backlog > 0 and failed >= 10:
            report.add("warn", "queue", f"{ns} has {failed} failed and active backlog {backlog}")
        elif failed >= 100:
            report.add("warn", "queue", f"{ns} failed count = {failed}")


def print_human(report: Report) -> None:
    print("=" * 72)
    print("MongoDB health scan")
    print(f"Time (UTC): {report.generated_at}")
    print(f"Target: {report.uri_host}")
    print("=" * 72)

    docker = report.sections.get("docker") or {}
    if docker.get("present"):
        print("\n[Docker container]")
        print(f"  name={docker.get('container')} status={docker.get('status')} oom_killed={docker.get('oom_killed')}")
        if docker.get("mem_usage"):
            print(f"  mem={docker.get('mem_usage')} mem%={docker.get('mem_percent')} cpu%={docker.get('cpu_percent')}")
        if docker.get("cpu_limit"):
            print(f"  limits: cpu={docker.get('cpu_limit')} mem_bytes={docker.get('mem_limit_bytes')}")
        if docker.get("data_db_df"):
            print(f"  disk: {docker.get('data_db_df')}")

    ss = report.sections.get("server_status") or {}
    if ss:
        print("\n[Server]")
        print(f"  version={ss.get('version')} uptime_hours={ss.get('uptime_hours')}")
        c = ss.get("connections") or {}
        print(
            f"  connections: current={c.get('current')} available={c.get('available')} "
            f"active={c.get('active')} rejected={c.get('rejected')} util={c.get('utilization')}"
        )
        m = ss.get("memory") or {}
        print(f"  mem resident_mb={m.get('resident_mb')} virtual_mb={m.get('virtual_mb')}")
        wt = ss.get("wired_tiger_cache") or {}
        print(
            f"  wiredTiger cache: {wt.get('used_mb')} / {wt.get('max_mb')} MB "
            f"(util={wt.get('utilization')})"
        )
        gl = ss.get("global_lock") or {}
        print(f"  globalLock queue: {gl.get('current_queue')} active_clients: {gl.get('active_clients')}")
        print(f"  opcounters: {ss.get('opcounters')}")

    ops = report.sections.get("current_ops") or {}
    print(f"\n[Current operations] active_non_idle={ops.get('active_non_idle')}")
    if ops.get("ops_by_ns"):
        print(f"  by_ns: {ops.get('ops_by_ns')}")
    for op in ops.get("long_running_ops") or []:
        print(f"  long: {op}")

    dbs = report.sections.get("databases") or []
    if dbs:
        print("\n[Databases by storage (MB)]")
        for row in dbs:
            print(
                f"  {row['db']}: storage={row['storage_mb']} data={row['data_mb']} "
                f"index={row['index_mb']} cols={row.get('collections')} objs={row.get('objects')}"
            )

    tops = report.sections.get("top_collections") or []
    if tops:
        print("\n[Top collections by storage]")
        for row in tops:
            print(f"  {row['ns']}: storage_mb={row['storage_mb']} count={row.get('count')}")

    queues = report.sections.get("queues") or []
    if queues:
        print("\n[Job queues]")
        for row in queues:
            if row.get("missing"):
                print(f"  {row['ns']}: (collection missing)")
            elif row.get("error"):
                print(f"  {row['ns']}: error={row['error']}")
            else:
                print(
                    f"  {row['ns']}: backlog={row.get('backlog')} "
                    f"status_counts={row.get('status_counts')}"
                )

    print("\n[Findings]")
    if not report.findings:
        print("  None — no heuristic warnings.")
    else:
        for f in report.findings:
            print(f"  [{f.level.upper()}] {f.category}: {f.message}")

    print("\n" + "=" * 72)
    code = report.worst_exit_code()
    print(f"Exit code: {code} (0=ok, 1=warn, 2=crit)")
    print("=" * 72)


def build_report(uri: str, container: Optional[str], top_n: int) -> Report:
    report = Report(
        generated_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        uri_host=_uri_host(uri),
    )
    if container:
        report.sections["docker"] = docker_container_stats(container)

    client = MongoClient(uri, serverSelectionTimeoutMS=10_000, connectTimeoutMS=10_000)
    try:
        client.admin.command("ping")
        report.sections["server_status"] = collect_server_status(client)
        report.sections["current_ops"] = collect_current_ops(client)
        report.sections["databases"] = collect_db_stats(client)
        report.sections["top_collections"] = collect_top_collections(client, limit=top_n)
        report.sections["queues"] = collect_queue_depths(client)
    finally:
        client.close()

    apply_heuristics(report, report.sections.get("docker") or {})
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="MongoDB bottleneck scan for quant infrastructure")
    parser.add_argument("--uri", help="MongoDB URI (overrides env and .env files)")
    parser.add_argument(
        "--container",
        default=DEFAULT_CONTAINER,
        help=f"Docker container for host stats (default: {DEFAULT_CONTAINER}); pass empty to skip",
    )
    parser.add_argument("--top", type=int, default=15, help="Top collections to list")
    parser.add_argument("--json", action="store_true", help="Print JSON instead of text")
    args = parser.parse_args()

    try:
        uri = resolve_uri(args.uri)
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2

    container = args.container.strip() or None
    t0 = time.perf_counter()
    try:
        report = build_report(uri, container, args.top)
    except PyMongoError as exc:
        print(f"MongoDB error: {exc}", file=sys.stderr)
        print(f"URI: {_redact_uri(uri)}", file=sys.stderr)
        return 2

    elapsed = time.perf_counter() - t0
    report.sections["scan_seconds"] = round(elapsed, 2)

    if args.json:
        payload = {
            "generated_at": report.generated_at,
            "uri_host": report.uri_host,
            "scan_seconds": report.sections["scan_seconds"],
            "sections": report.sections,
            "findings": [{"level": f.level, "category": f.category, "message": f.message} for f in report.findings],
            "exit_code": report.worst_exit_code(),
        }
        print(json.dumps(payload, indent=2, default=str))
    else:
        print_human(report)
        print(f"Scan completed in {report.sections['scan_seconds']}s")

    return report.worst_exit_code()


if __name__ == "__main__":
    sys.exit(main())
