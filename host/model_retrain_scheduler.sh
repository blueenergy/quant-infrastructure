#!/usr/bin/env bash
# Monthly/quarterly model retrain scheduler.
# Reads quant_ml.model_retrain_schedules and enqueues versioned training jobs.
set -euo pipefail

LOG=/home/shuyolin/trading/logs/model_retrain_scheduler.log
NOTIFY=/home/shuyolin/notify_dingtalk.sh
mkdir -p "$(dirname "$LOG")"

if ! docker exec quant-api python -m services.model_retrain_scheduler >> "$LOG" 2>&1; then
  if [ -x "$NOTIFY" ]; then
    "$NOTIFY" "Model retrain scheduler failed" "See $LOG" >/dev/null 2>&1 || true
  fi
  exit 1
fi
