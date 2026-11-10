#!/usr/bin/env python3
"""Host-side quantTrader instance reconciler.

Desired state comes from ``finance.securities_accounts``:

    desired_running = live_trading_enabled AND auto_manage AND mapping_complete

It only acts on accounts with ``auto_manage=true``.  Containers are never
removed (only started/stopped); trader data volumes are left untouched.

Safety:
- ``TRADER_RECONCILER_ENABLED`` (default false) gates all docker actions.
- ``TRADER_RECONCILER_CREATE`` (default true) allows creating a missing
  container for an account with a complete mapping; set false to start/stop
  existing containers only.
- Alerts are limited to the continuous-auction windows and deduped per account
  for 30 minutes.  ``TRADER_RECONCILER_DRY_RUN`` skips docker/alerts.

Status is written to ``finance.trader_instance_status`` for the admin page.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from pymongo import MongoClient

TZ = timezone(timedelta(hours=8), name="Asia/Shanghai")
REPO = Path("/home/shuyolin/trading/quant-infrastructure")
COMMON_ENV = REPO / "apps/env/common.env"
VERSIONS = REPO / "apps/versions.env"
AUTOGEN_DIR = REPO / "apps/data/trader-autogen"
DATA_DIR = REPO / "apps/data"
LOG_DIR = REPO / "apps/logs"
NOTIFY = Path("/home/shuyolin/notify_dingtalk.sh")

# Continuous auction windows; lunch break excluded.
ALERT_WINDOWS = [((9, 40), (11, 30)), ((13, 5), (15, 0))]
SYNC_STALE_SECONDS = 180
WORKER_STALE_SECONDS = 180
ALERT_MIN_INTERVAL_SEC = 1800
MANAGED_NAME_PREFIX = "quant-trader"


def _log(msg: str) -> None:
    print(f"[{datetime.now(TZ).strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def _env_flag(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _read_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def _mongo_uri() -> str:
    common = _read_env_file(COMMON_ENV)
    uri = common.get("MONGO_URI", "")
    if not uri:
        raise RuntimeError("MONGO_URI missing in common.env")
    return uri.replace("mongodb:27017", "localhost:27017")


def _image() -> str:
    versions = _read_env_file(VERSIONS)
    tag = versions.get("QUANT_TRADER_IMAGE_TAG", "").strip()
    if not tag:
        raise RuntimeError("QUANT_TRADER_IMAGE_TAG missing in versions.env")
    repo_prefix = "crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com/wukongquant/quant-trader"
    return f"{repo_prefix}:{tag}"


def _now_ts() -> float:
    return time.time()


def _iso(ts) -> str | None:
    if not isinstance(ts, (int, float)) or ts <= 0:
        return None
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone(TZ).isoformat()


def _docker(*args: str, timeout: int = 30) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["docker", *args], capture_output=True, text=True, timeout=timeout
    )


def _container_state(name: str) -> str:
    proc = _docker("inspect", "-f", "{{.State.Status}}", name, timeout=15)
    if proc.returncode != 0:
        return "missing"
    return (proc.stdout or "").strip() or "unknown"


def _start_container(name: str) -> None:
    proc = _docker("start", name, timeout=60)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "").strip()[:200])


def _stop_container(name: str) -> None:
    proc = _docker("stop", "-t", "15", name, timeout=90)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "").strip()[:200])


def _mapping_complete(account: dict) -> bool:
    return bool(
        account.get("qmt_account_id")
        and account.get("qmt_mailbox_root")
        and account.get("trader_client_id")
    )


def _container_name(account: dict) -> str:
    name = str(account.get("trader_container_name") or "").strip()
    if name:
        return name
    suffix = str(account.get("_id"))[-6:]
    return f"quant-trader-{suffix}"


def _generate_config(account: dict) -> Path:
    uri = _mongo_uri().replace("localhost:27017", "127.0.0.1:27017")
    config = {
        "backend_mode": "db",
        "mongo_uri": uri,
        "mongo_db": "finance",
        "user_id": str(account.get("user_id")),
        "poll_interval": 0.2,
        "log_level": "INFO",
        "broker": "qmt_bridge",
        "securities_account_id": str(account.get("_id")),
        "qmt_bridge": {
            "account_id": str(account.get("qmt_account_id")),
            "transport": "file",
            "rpc_timeout_seconds": 6.0,
            "rpc_allow_order_methods": True,
            "file": {
                "root": "/app/bqbox/trade",
                "client_id": str(account.get("trader_client_id")),
                "poll_interval_seconds": 0.02,
            },
            "vendor_src": "vendor/xtquant_big_convert/src",
        },
        "execution": {
            "buy_order_timeout_seconds": 3600,
            "cancel_retry_grace_seconds": 15,
            "cancel_retry_interval_seconds": 25,
            "use_activate_after": True,
            "trading_sessions": "CN_A",
            "reject_signals_outside_session": False,
            "sell_barrier_mode": "off",
            "execution_events_mode": "off",
            "force_cancel_before_close_enabled": True,
            "force_cancel_before_close_time": "14:55",
        },
    }
    AUTOGEN_DIR.mkdir(parents=True, exist_ok=True)
    path = AUTOGEN_DIR / f"{account['_id']}.json"
    path.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def _create_container(account: dict) -> None:
    name = _container_name(account)
    if not name.startswith(MANAGED_NAME_PREFIX):
        raise RuntimeError(f"refusing to manage non-trader container: {name}")
    mailbox = Path(str(account.get("qmt_mailbox_root")))
    if not mailbox.is_dir():
        raise RuntimeError(f"QMT mailbox not found: {mailbox}")
    config_path = _generate_config(account)
    data_dir = DATA_DIR / name
    log_dir = LOG_DIR / name
    data_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)
    proc = _docker(
        "run", "-d",
        "--name", name,
        "--restart", "unless-stopped",
        "--network", "host",
        "-e", "TZ=Asia/Shanghai",
        "-e", "QUANT_TRADER_EXECUTION_OUTBOX_PATH=/app/data/execution_outbox.json",
        "-v", f"{config_path}:/app/config/config.json:ro",
        "-v", f"{mailbox}:/app/bqbox",
        "-v", f"{data_dir}:/app/data",
        "-v", f"{log_dir}:/root/.local/share/quantTrader/logs",
        _image(),
        timeout=180,
    )
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "").strip()[:300])


def _is_trading_day(calendar, today: str) -> bool:
    doc = calendar.find_one({"trade_date": today}, {"_id": 0, "is_open": 1})
    if doc:
        value = doc.get("is_open")
        return value in (1, "1", True)
    return datetime.strptime(today, "%Y%m%d").weekday() < 5


def _in_alert_window(now: datetime, calendar) -> bool:
    if not _is_trading_day(calendar, now.strftime("%Y%m%d")):
        return False
    minute = now.hour * 60 + now.minute
    return any(
        start[0] * 60 + start[1] <= minute <= end[0] * 60 + end[1]
        for start, end in ALERT_WINDOWS
    )


def _send_alert(title: str, text: str) -> None:
    if not NOTIFY.exists():
        _log(f"notify script missing; alert not sent: {title} {text}")
        return
    proc = subprocess.run([str(NOTIFY), title, text], capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        _log(f"alert send failed: {(proc.stderr or proc.stdout or '').strip()[:200]}")


def _accessible_ts(value) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, datetime):
        return value.timestamp()
    return None


def _age_seconds(value, now_ts: float) -> float | None:
    ts = _accessible_ts(value)
    if ts is None:
        return None
    return now_ts - ts


def _health_for(
    account: dict,
    *,
    container_state: str,
    account_synced_at,
    worker_seen_at,
    now_ts: float,
) -> tuple[str, str]:
    if not account.get("live_trading_enabled"):
        return "not_managed", "未开启实盘交易信号"
    if not _mapping_complete(account):
        return "no_mapping", "已开启实盘但缺少执行端点映射"
    if container_state == "missing":
        return "not_running", "实例容器不存在"
    if container_state != "running":
        return "not_running", f"实例容器状态：{container_state}"
    sync_age = _age_seconds(account_synced_at, now_ts)
    if sync_age is None:
        return "sync_stale", "尚未同步账户数据"
    if sync_age > SYNC_STALE_SECONDS:
        return "sync_stale", f"账户同步已过期 {int(sync_age)} 秒（QMT 策略/桥可能失效）"
    worker_age = _age_seconds(worker_seen_at, now_ts)
    if worker_age is not None and worker_age > WORKER_STALE_SECONDS:
        return "worker_stale", f"实例心跳已过期 {int(worker_age)} 秒"
    return "ok", "正常"


def _maybe_alert(status: dict, in_window: bool, now_ts: float, dry_run: bool) -> None:
    health = status.get("health")
    if health in (None, "ok", "not_managed"):
        return
    if not in_window:
        return
    last_at = status.get("last_alert_at") or 0
    last_reason = status.get("last_alert_reason")
    if last_reason == health and now_ts - float(last_at) < ALERT_MIN_INTERVAL_SEC:
        return
    title = f"交易实例异常：{status.get('account_id')}"
    text = (
        f"账户 {status.get('account_id')}（{status.get('broker')}）"
        f" 实例 {status.get('container_name')}：{status.get('health_reason')}；"
        f"容器={status.get('container_state')}"
    )
    if dry_run:
        _log(f"[dry-run] alert: {title} / {text}")
    else:
        _send_alert(title, text)
    status["last_alert_at"] = now_ts
    status["last_alert_reason"] = health


def main() -> None:
    enabled = _env_flag("TRADER_RECONCILER_ENABLED", False)
    create_missing = _env_flag("TRADER_RECONCILER_CREATE", True)
    dry_run = _env_flag("TRADER_RECONCILER_DRY_RUN", False)

    client = MongoClient(_mongo_uri(), serverSelectionTimeoutMS=5000)
    finance = client["finance"]
    calendar = client["quant_data"]["trade_calendar"]
    status_coll = finance["trader_instance_status"]
    status_coll.create_index([("securities_account_id", 1)], unique=True, background=True)

    now = datetime.now(TZ)
    now_ts = _now_ts()
    in_window = _in_alert_window(now, calendar)

    accounts = list(
        finance["securities_accounts"].find({"account_type": "real"}).sort("created_at", 1)
    )
    for account in accounts:
        sec_id = str(account["_id"])
        user_id = str(account.get("user_id") or "")
        desired = bool(
            account.get("live_trading_enabled")
            and account.get("auto_manage")
            and _mapping_complete(account)
        )
        name = _container_name(account)
        state = _container_state(name)

        action = ""
        if enabled and account.get("auto_manage"):
            try:
                if desired and state in ("missing", "created", "exited", "dead"):
                    if state == "missing" and not create_missing:
                        action = "skip-create-disabled"
                    else:
                        if state == "missing":
                            if not dry_run:
                                _create_container(account)
                            action = "created"
                        else:
                            if not dry_run:
                                _start_container(name)
                            action = "started"
                        state = _container_state(name)
                elif not desired and state == "running":
                    if not dry_run:
                        _stop_container(name)
                    action = "stopped"
                    state = _container_state(name)
                elif desired and state == "running":
                    action = "noop"
            except Exception as exc:  # noqa: BLE001 - one account must not stop the loop
                action = f"error: {exc}"
                _log(f"account {account.get('account_id')} action failed: {exc}")

        account_row = finance["trader_accounts"].find_one(
            {"user_id": user_id, "securities_account_id": sec_id}, sort=[("synced_at", -1)]
        ) or {}
        worker_row = finance["worker_status"].find_one(
            {"user_id": user_id, "worker_id": f"quantTrader:{sec_id}"}
        ) or {}
        account_synced_at = account_row.get("synced_at")
        worker_seen_at = worker_row.get("last_seen_at")

        health, reason = _health_for(
            account,
            container_state=state,
            account_synced_at=account_synced_at,
            worker_seen_at=worker_seen_at,
            now_ts=now_ts,
        )
        status = {
            "securities_account_id": sec_id,
            "user_id": user_id,
            "account_id": account.get("account_id"),
            "broker": account.get("broker"),
            "live_trading_enabled": bool(account.get("live_trading_enabled")),
            "auto_manage": bool(account.get("auto_manage", False)),
            "mapping_complete": _mapping_complete(account),
            "desired_running": desired,
            "container_name": name,
            "container_state": state,
            "account_synced_at": account_synced_at,
            "worker_seen_at": worker_seen_at,
            "health": health,
            "health_reason": reason,
            "last_action": action,
            "updated_at": now_ts,
        }
        previous = status_coll.find_one({"securities_account_id": sec_id}) or {}
        for key in ("last_alert_at", "last_alert_reason"):
            if previous.get(key) is not None:
                status[key] = previous[key]
        _maybe_alert(status, in_window, now_ts, dry_run)
        if not dry_run:
            status_coll.update_one(
                {"securities_account_id": sec_id}, {"$set": status}, upsert=True
            )
        _log(
            f"{account.get('account_id')} desired={desired} state={state} "
            f"health={health} action={action or '-'} ({reason})"
        )

    if not in_window:
        _log("outside alert window; no alerts")
    if not enabled:
        _log("TRADER_RECONCILER_ENABLED is false; docker actions skipped (status only)")


if __name__ == "__main__":
    main()
