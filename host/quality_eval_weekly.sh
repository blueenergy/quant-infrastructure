#!/bin/bash
# Weekly analysis-quality evaluation.
# Runs inside quant-analyzer (LLM deps) and reports one summary line per type.
# Cron: 0 18 * * 5
set -u

LOG=/home/shuyolin/trading/logs/quality_eval.log
LIMIT="${QUALITY_EVAL_LIMIT:-20}"
DAY=$(date +%Y%m%d)

OUT=$(docker exec apps-quant-analyzer-1 python -m quant_analyzer.quality_eval \
  --type all --limit "$LIMIT" --llm \
  --out "/app/logs/quality_eval_${DAY}.json" 2>&1)
rc=$?

{
  echo "[$(date '+%F %T')] limit=$LIMIT rc=$rc"
  echo "$OUT"
} >> "$LOG"

if [ "$rc" -ne 0 ]; then
  NOTIFY_PREFIX="" /home/shuyolin/notify_dingtalk.sh \
    "每周分析质量评测失败" "rc=$rc，详见 logs/quality_eval.log" >/dev/null 2>&1
  exit 0
fi

summary=$(echo "$OUT" | grep '^== ' || true)
if [ -n "$summary" ] && [ "${QUALITY_EVAL_NOTIFY:-1}" = "1" ]; then
  NOTIFY_PREFIX="" /home/shuyolin/notify_dingtalk.sh "每周分析质量评测" "$summary" >/dev/null 2>&1
fi
