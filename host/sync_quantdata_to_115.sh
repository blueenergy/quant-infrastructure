#!/usr/bin/env bash
# 本机 quant_data -> 115 MongoDB 每日同步（收盘后），专补 115 自己长不出来的数据。
#
# 背景：115 没有 QMT，`quant_data.minute_bars` 停在 2026-04-17 且只有旧的
# 58 只 watchlist；国家队 ETF 监控（services/etf_national_team.py）直接报
# `no minute_bars data for the national-team pool`。
#
# 同步范围：
#   - minute_bars：首次/--full 全量 --drop；之后按 trade_date 增量追加
#   - index_prices：每次全量 --drop（约 3.4 万行，补 115 缺的
#     000001.SH / 399006.SZ / 932000.CSI 历史）
#
# 不碰：
#   - etf_daily / etf_shares / etf_share_size：115 的 data-engine 自己从
#     Tushare 同步，2026-11-07 实测与本地一致或更新（etf_shares 115 甚至新一天）
#   - quant_realtime：由 sync_realtime_to_115.sh 负责
#
# 用法：
#   sync_quantdata_to_115.sh            # 增量（cron 用这个）
#   sync_quantdata_to_115.sh --full     # 首次全量：minute_bars 整集合 drop+重灌
#
# 凭据不落盘：运行时从两端 quant-api 容器的 MONGO_URI 读取。
#
# 背景与坑：llm-wiki/projects/trading/ops/115-realtime-sync-20261106.md

set -euo pipefail

KEY=${SYNC_SSH_KEY:-/home/shuyolin/.ssh/volcano-volc.pem}
HOST=${SYNC_115_HOST:-115.190.172.95}
LOCAL_MONGO=${LOCAL_MONGO_CONTAINER:-quant-mongodb}
REMOTE_MONGO=${REMOTE_MONGO_CONTAINER:-quant-mongodb}
LOCAL_API=${LOCAL_API_CONTAINER:-quant-api}
REMOTE_API=${REMOTE_API_CONTAINER:-quant-api}

DATA_DB=quant_data
MB_COLLECTION=minute_bars
IDX_COLLECTION=index_prices

LOG=/home/shuyolin/trading/logs/quantdata_sync_115.log
LOCK=/tmp/sync_quantdata_to_115.lock
NOTIFY=/home/shuyolin/notify_dingtalk.sh

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

log() { echo "[$(date '+%F %T')] $*"; }
fail() {
  log "ERROR: $*"
  "$NOTIFY" "115 quant_data 同步失败" "$*" >/dev/null 2>&1 || true
  exit 1
}

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { log "another run active; skip"; exit 0; }
fi

MODE=incremental
case "${1:-}" in
  --full) MODE=full ;;
  ""|--incremental) ;;
  *) echo "usage: $0 [--full]"; exit 2 ;;
esac

SSH_OPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

log "start mode=$MODE target=$HOST"

LURI=$(docker exec "$LOCAL_API" printenv MONGO_URI) || fail "read local MONGO_URI"
RURI=$(ssh "${SSH_OPTS[@]}" root@"$HOST" "docker exec $REMOTE_API printenv MONGO_URI") || fail "read 115 MONGO_URI over ssh"
[ -n "$LURI" ] && [ -n "$RURI" ] || fail "empty MONGO_URI"

# 在指定一端跑一段 mongosh JS 并打印结果
run_mongo() {
  local uri=$1 where=$2 js=$3
  if [ "$where" = local ]; then
    docker exec "$LOCAL_MONGO" mongosh "$uri" --quiet --eval "$js"
  else
    ssh "${SSH_OPTS[@]}" root@"$HOST" "docker exec -i $REMOTE_MONGO mongosh $(printf %q "$uri") --quiet --eval $(printf %q "$js")"
  fi
}

max_field_js() {
  printf 'var d=db.getSiblingDB("%s").getCollection("%s").find({},{%s:1}).sort({%s:-1}).limit(1).toArray()[0]; print(d?d.%s:"")' \
    "$1" "$2" "$3" "$3" "$3"
}

run_max() {  # $1=uri $2=local|remote $3=collection
  run_mongo "$1" "$2" "$(max_field_js "$DATA_DB" "$3" trade_date)"
}

# ---- 1) index_prices：每次全量 --drop（量小，顺带修漂移）----
log "sync $IDX_COLLECTION (full, --drop)"
if ! docker exec "$LOCAL_MONGO" mongodump --uri "$LURI" --db "$DATA_DB" -c "$IDX_COLLECTION" --archive --gzip \
  | ssh "${SSH_OPTS[@]}" root@"$HOST" "docker exec -i $REMOTE_MONGO mongorestore --archive --gzip --drop --uri $(printf %q "$RURI")"; then
  fail "$IDX_COLLECTION sync failed"
fi

# ---- 2) minute_bars：全量或增量 ----
SRC_MAX=$(run_max "$LURI" local "$MB_COLLECTION") || fail "query local minute_bars max"
DST_MAX=$(run_max "$RURI" remote "$MB_COLLECTION") || fail "query 115 minute_bars max"
log "minute_bars max before: local=${SRC_MAX:-<empty>} 115=${DST_MAX:-<empty>}"
[ -n "$SRC_MAX" ] || fail "local minute_bars is empty"

MB_DROP=""
QUERY=""
if [ "$MODE" = full ] || [ -z "$DST_MAX" ]; then
  MB_DROP="--drop"
else
  QUERY=$(printf '{"trade_date":{"$gt":"%s"}}' "$DST_MAX")
fi

log "sync $MB_COLLECTION: ${QUERY:-FULL (drop+reload)}"
MB_DUMP=(docker exec "$LOCAL_MONGO" mongodump --uri "$LURI" --db "$DATA_DB" -c "$MB_COLLECTION" --archive --gzip)
[ -n "$QUERY" ] && MB_DUMP+=(--query "$QUERY")
if ! "${MB_DUMP[@]}" \
  | ssh "${SSH_OPTS[@]}" root@"$HOST" "docker exec -i $REMOTE_MONGO mongorestore --archive --gzip $MB_DROP --uri $(printf %q "$RURI")"; then
  fail "$MB_COLLECTION sync failed"
fi

# ---- 3) 校验 ----
NEW_SRC_MAX=$(run_max "$LURI" local "$MB_COLLECTION") || fail "query local minute_bars max after"
NEW_DST_MAX=$(run_max "$RURI" remote "$MB_COLLECTION") || fail "query 115 minute_bars max after"
log "minute_bars max after: local=$NEW_SRC_MAX 115=$NEW_DST_MAX"
[ "$NEW_SRC_MAX" = "$NEW_DST_MAX" ] || fail "minute_bars max mismatch (local=$NEW_SRC_MAX 115=$NEW_DST_MAX)"

SYM_JS='var d=db.getSiblingDB("quant_data").getCollection("minute_bars"); print(d.distinct("symbol").length)'
SRC_SYMS=$(run_mongo "$LURI" local "$SYM_JS") || fail "count local minute_bars symbols"
DST_SYMS=$(run_mongo "$RURI" remote "$SYM_JS") || fail "count 115 minute_bars symbols"
log "minute_bars symbols: local=$SRC_SYMS 115=$DST_SYMS"
[ "$SRC_SYMS" = "$DST_SYMS" ] || fail "minute_bars symbol count mismatch (local=$SRC_SYMS 115=$DST_SYMS)"

CNT_JS='var d=db.getSiblingDB("quant_data").getCollection("index_prices"); print(d.countDocuments({}))'
SRC_IDX=$(run_mongo "$LURI" local "$CNT_JS") || fail "count local index_prices"
DST_IDX=$(run_mongo "$RURI" remote "$CNT_JS") || fail "count 115 index_prices"
log "index_prices count: local=$SRC_IDX 115=$DST_IDX"
[ "$SRC_IDX" = "$DST_IDX" ] || fail "index_prices count mismatch (local=$SRC_IDX 115=$DST_IDX)"

# ---- 4) 115 磁盘只告警、不删数据（10 月已两次写满）----
USAGE=$(ssh "${SSH_OPTS[@]}" root@"$HOST" "df / | awk 'NR==2{gsub(\"%\",\"\",\$5); print \$5}'" || true)
if [ -n "$USAGE" ]; then
  log "115 / disk usage: ${USAGE}%"
  if [ "$USAGE" -ge 85 ]; then
    "$NOTIFY" "115 磁盘告警" "sync_quantdata_to_115: / 已用 ${USAGE}%，请清理镜像/日志" >/dev/null 2>&1 || true
  fi
fi

log "done"
