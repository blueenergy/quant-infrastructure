#!/usr/bin/env python3
"""Analysis-task watchdog.

Runs inside the ``quant-api`` container (stdin, pymongo available) and prints
an alert message to stdout when it finds:

- newly failed / parse-error tasks (lookback window)
- tasks stuck in ``processing`` past the stale threshold
- pending backlog older than the backlog threshold

Dedupe state lives in ``finance.ops_watchdog_state`` so the same task is not
reported more than once per repeat window. ``--dry-run`` prints the alert
without writing state.

Stdout is only used for alerts; exceptions go to stderr and exit non-zero.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta
from typing import Any, Dict, List, Tuple


def _int_env(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        return default


LOOKBACK_MINUTES = _int_env("WATCHDOG_LOOKBACK_MINUTES", 15)
STALE_MINUTES = _int_env("WATCHDOG_STALE_MINUTES", 45)
BACKLOG_MINUTES = _int_env("WATCHDOG_BACKLOG_MINUTES", 30)
REPEAT_HOURS = _int_env("WATCHDOG_REPEAT_HOURS", 6)
MAX_ITEMS = _int_env("WATCHDOG_MAX_ITEMS", 10)
DRY_RUN = "--dry-run" in sys.argv


def _short(value: Any, limit: int = 120) -> str:
    text = str(value or "").replace("\n", " ").strip()
    return text[:limit] + ("..." if len(text) > limit else "")


def _fmt_dt(value: Any) -> str:
    if isinstance(value, datetime):
        return value.strftime("%m-%d %H:%M")
    return str(value or "?")


def _age_minutes(value: Any, now: datetime) -> float:
    if not isinstance(value, datetime):
        return 0.0
    return max(0.0, (now - value).total_seconds() / 60)


def main() -> int:
    from pymongo import MongoClient

    client = MongoClient(os.environ["MONGO_URI"])
    db = client[os.getenv("MONGO_DB", "finance")]
    tasks = db["analysis_tasks"]
    state = db["ops_watchdog_state"]

    now = datetime.now()
    since = now - timedelta(minutes=LOOKBACK_MINUTES)
    stale_cutoff = now - timedelta(minutes=STALE_MINUTES)
    backlog_cutoff = now - timedelta(minutes=BACKLOG_MINUTES)
    repeat_delta = timedelta(hours=REPEAT_HOURS)

    def recently_alerted(key: str) -> bool:
        doc = state.find_one({"_id": key})
        last = (doc or {}).get("last_alert_at")
        return isinstance(last, datetime) and (now - last) < repeat_delta

    sections: List[str] = []
    mark_keys: List[Tuple[str, Dict[str, Any]]] = []

    # 1) Terminal failures / parse errors inside the lookback window.
    terminal = [
        ("failed", "failed_at", "失败"),
        ("completed_with_parse_error", "completed_at", "解析失败"),
    ]
    for status, ts_field, label in terminal:
        docs = list(
            tasks.find({"status": status, ts_field: {"$gte": since}})
            .sort(ts_field, -1)
            .limit(50)
        )
        lines: List[str] = []
        for doc in docs:
            # One alert per task, even when it moves between terminal states
            # (e.g. stale -> failed after the reclaimer marks it too_old).
            key = f"task:{doc['_id']}"
            if recently_alerted(key):
                continue
            lines.append(
                "- {ts} {type} {id}: {error} (model={model})".format(
                    ts=_fmt_dt(doc.get(ts_field)),
                    type=doc.get("type") or doc.get("task_type") or "?",
                    id=str(doc.get("_id")),
                    error=_short(doc.get("error") or ""),
                    model=_short((doc.get("llm_audit") or {}).get("llm_model_resolved") or "?", 40),
                )
            )
            mark_keys.append((key, {"status": status, "task_type": doc.get("type")}))
        if lines:
            shown = lines[:MAX_ITEMS]
            if len(lines) > MAX_ITEMS:
                shown.append(f"- ...共 {len(lines)} 条")
            sections.append(f"{label} {len(lines)} 条")
            sections.extend(shown)

    # 2) Stuck processing tasks.
    stale_docs = list(
        tasks.find(
            {
                "status": "processing",
                "$or": [
                    {"updated_at": {"$lt": stale_cutoff}},
                    {"updated_at": {"$exists": False}, "started_at": {"$lt": stale_cutoff}},
                ],
            }
        ).limit(50)
    )
    stale_lines: List[str] = []
    for doc in stale_docs:
        key = f"task:{doc['_id']}"
        if recently_alerted(key):
            continue
        age = _age_minutes(doc.get("started_at") or doc.get("updated_at"), now)
        stale_lines.append(
            "- {type} {id}: 已 {age:.0f} 分钟, worker={worker}".format(
                type=doc.get("type") or doc.get("task_type") or "?",
                id=str(doc.get("_id")),
                age=age,
                worker=_short(doc.get("worker_id") or "?", 40),
            )
        )
        mark_keys.append((key, {"status": "stale", "task_type": doc.get("type")}))
    if stale_lines:
        shown = stale_lines[:MAX_ITEMS]
        if len(stale_lines) > MAX_ITEMS:
            shown.append(f"- ...共 {len(stale_lines)} 条")
        sections.append(f"卡死 {len(stale_lines)} 条")
        sections.extend(shown)

    # 3) Pending backlog.
    backlog_count = tasks.count_documents(
        {"status": "pending", "created_at": {"$lt": backlog_cutoff}}
    )
    if backlog_count:
        key = "backlog"
        if not recently_alerted(key):
            oldest = tasks.find_one(
                {"status": "pending", "created_at": {"$lt": backlog_cutoff}},
                sort=[("created_at", 1)],
            )
            age = _age_minutes((oldest or {}).get("created_at"), now)
            sections.append(f"积压 {backlog_count} 条，最老 {age:.0f} 分钟")
            sections.append(f"- 最老任务: {str((oldest or {}).get('_id'))} {(oldest or {}).get('type')}")
            mark_keys.append((key, {"status": "backlog"}))

    # Prune old dedupe state opportunistically.
    if not DRY_RUN:
        try:
            state.delete_many({"last_alert_at": {"$lt": now - timedelta(days=7)}})
        except Exception:
            pass

    if not sections:
        return 0

    if not DRY_RUN:
        for key, extra in mark_keys:
            state.update_one(
                {"_id": key},
                {"$set": {"last_alert_at": now, **extra}},
                upsert=True,
            )

    print(f"分析任务看门狗 {now.strftime('%m-%d %H:%M')}")
    print("\n".join(sections))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # pragma: no cover - operational path
        print(f"watchdog failed: {exc}", file=sys.stderr)
        sys.exit(1)
