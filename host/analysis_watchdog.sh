#!/bin/bash
# Analysis-task watchdog wrapper.
# Runs the Python watchdog inside quant-api (has pymongo + env), then sends
# the alert from the host via notify_dingtalk.sh.
# Cron: */10 * * * * bash .../analysis_watchdog.sh >> .../logs/analysis_watchdog.log 2>&1
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ERR_FILE="/tmp/analysis_watchdog.err"

out=$(docker exec -i quant-api python3 - "$@" < "$SCRIPT_DIR/analysis_watchdog.py" 2>"$ERR_FILE")
rc=$?

if [ "$rc" -ne 0 ]; then
  echo "[$(date '+%F %T')] watchdog error rc=$rc"
  tail -5 "$ERR_FILE" 2>/dev/null
  exit 0
fi

if [ -z "$out" ]; then
  exit 0
fi

echo "[$(date '+%F %T')]"
echo "$out"

if [ "${WATCHDOG_NOTIFY:-1}" = "1" ] && [[ " $* " != *" --dry-run "* ]]; then
  # Production alerts should not carry the "[Claude]" prefix.
  NOTIFY_PREFIX="" /home/shuyolin/notify_dingtalk.sh "分析任务看门狗" "$out"
fi
