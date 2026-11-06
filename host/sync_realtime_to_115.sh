#!/usr/bin/env bash
# 本机 quant_realtime -> 115 MongoDB 每日同步（收盘后）。
#
# 背景：115 是最小业务节点，没有 QMT，quant_realtime 自己长不出数据。
# 本脚本把本机 4 个集合灌到 115：
#   - market_spectrum_realtime_daily / volume_price_realtime_latest /
#     index_realtime_snapshots：每次全量 --drop 覆盖（都在几 MB 量级）
#   - realtime_sector_strength：按 snapshot_time 增量追加（默认不删历史）
#
# 不同步 bridge_heartbeat_alerts / bigqmt_shadow_snapshots：
# 前者是本机桥的运维态（115 没有桥，灌过去只会误导），后者是已停用的实验。
#
# 用法：
#   sync_realtime_to_115.sh            # 增量（cron 用这个）
#   sync_realtime_to_115.sh --full     # 首次全量：整集合 drop + 重灌
#
# 凭据不落盘：运行时从两端 quant-api 容器的 MONGO_URI 读取。
# 115 的 MONGO_INITDB_* 已于 2026-10 轮转，不能用来认证。
#
# 背景与坑：llm-wiki/projects/trading/ops/115-realtime-sync-20261106.md

set -euo pipefail

KEY=${SYNC_SSH_KEY:-/home/shuyolin/.ssh/volcano-volc.pem}
HOST=${SYNC_115_HOST:-115.190.172.95}
LOCAL_MONGO=${LOCAL_MONGO_CONTAINER:-quant-mongodb}
REMOTE_MONGO=${REMOTE_MONGO_CONTAINER:-quant-mongodb}
LOCAL_API=${LOCAL_API_CONTAINER:-quant-api}
REMOTE_API=${REMOTE_API_CONTAINER:-quant-api}

DB=quant_realtime
SMALL_COLLECTIONS=(market_spectrum_realtime_daily volume_price_realtime_latest index_realtime_snapshots)
BIG_COLLECTION=realtime_sector_strength

LOG=/home/shuyolin/trading/logs/realtime_sync_115.log
LOCK=/tmp/sync_realtime_to_115.lock
NOTIFY=/home/shuyolin/notify_dingtalk.sh

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

log() { echo "[$(date '+%F %T')] $*"; }
fail() {
  log "ERROR: $*"
  "$NOTIFY" "115 realtime 同步失败" "$*" >/dev/null 2>&1 || true
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

# 取 realtime_sector_strength 的最大 snapshot_time；$1=URI，$2=local|remote
max_snapshot() {
  local uri=$1 where=$2
  local js='var d=db.getSiblingDB("quant_realtime").realtime_sector_strength.find({},{snapshot_time:1}).sort({snapshot_time:-1}).limit(1).toArray()[0]; print(d?d.snapshot_time:"")'
  if [ "$where" = local ]; then
    docker exec "$LOCAL_MONGO" mongosh "$uri" --quiet --eval "$js"
  else
    ssh "${SSH_OPTS[@]}" root@"$HOST" "docker exec -i $REMOTE_MONGO mongosh $(printf %q "$uri") --quiet --eval $(printf %q "$js")"
  fi
}

counts() {
  local uri=$1 where=$2
  # 用 countDocuments 而不是 estimatedDocumentCount：本地集合有删改，
  # fast count 会停在过期值（2026-11-06 首次校验就被它坑过）。
  local js='var dbx=db.getSiblingDB("quant_realtime"); ["market_spectrum_realtime_daily","volume_price_realtime_latest","index_realtime_snapshots"].forEach(function(n){print(n+"="+dbx[n].countDocuments({}))});'
  if [ "$where" = local ]; then
    docker exec "$LOCAL_MONGO" mongosh "$uri" --quiet --eval "$js"
  else
    ssh "${SSH_OPTS[@]}" root@"$HOST" "docker exec -i $REMOTE_MONGO mongosh $(printf %q "$uri") --quiet --eval $(printf %q "$js")"
  fi
}

SOURCE_MAX=$(max_snapshot "$LURI" local) || fail "query local max snapshot_time"
TARGET_MAX=$(max_snapshot "$RURI" remote) || fail "query 115 max snapshot_time"
log "max snapshot_time before: local=${SOURCE_MAX:-<empty>} 115=${TARGET_MAX:-<empty>}"
[ -n "$SOURCE_MAX" ] || fail "local realtime_sector_strength is empty"

FULL_BIG=0
QUERY=""
if [ "$MODE" = full ] || [ -z "$TARGET_MAX" ]; then
  FULL_BIG=1
else
  QUERY=$(printf '{"snapshot_time":{"$gt":"%s"}}' "$TARGET_MAX")
fi

# ---- 1) 三个小集合：全量覆盖 ----
# 注意：mongodump 的 -c 只能带一个（重复传只认最后一个），所以逐个跑。
for c in "${SMALL_COLLECTIONS[@]}"; do
  log "sync $c (full, --drop)"
  if ! docker exec "$LOCAL_MONGO" mongodump --uri "$LURI" --db "$DB" -c "$c" --archive --gzip \
    | ssh "${SSH_OPTS[@]}" root@"$HOST" "docker exec -i $REMOTE_MONGO mongorestore --archive --gzip --drop --uri $(printf %q "$RURI")"; then
    fail "$c sync failed"
  fi
done

# ---- 2) realtime_sector_strength：全量或增量 ----
BIG_DUMP=(docker exec "$LOCAL_MONGO" mongodump --uri "$LURI" --db "$DB" -c "$BIG_COLLECTION" --archive --gzip)
[ -n "$QUERY" ] && BIG_DUMP+=(--query "$QUERY")
RESTORE_DROP=""
[ "$FULL_BIG" = 1 ] && RESTORE_DROP="--drop"
log "sync $BIG_COLLECTION: ${QUERY:-FULL (drop+reload)}"
if ! "${BIG_DUMP[@]}" \
  | ssh "${SSH_OPTS[@]}" root@"$HOST" "docker exec -i $REMOTE_MONGO mongorestore --archive --gzip $RESTORE_DROP --uri $(printf %q "$RURI")"; then
  fail "$BIG_COLLECTION sync failed"
fi

# ---- 3) 校验 ----
NEW_SOURCE_MAX=$(max_snapshot "$LURI" local) || fail "query local max after sync"
NEW_TARGET_MAX=$(max_snapshot "$RURI" remote) || fail "query 115 max after sync"
log "max snapshot_time after: local=$NEW_SOURCE_MAX 115=$NEW_TARGET_MAX"
[ "$NEW_SOURCE_MAX" = "$NEW_TARGET_MAX" ] || fail "max snapshot_time mismatch (local=$NEW_SOURCE_MAX 115=$NEW_TARGET_MAX)"

SRC_COUNTS=$(counts "$LURI" local) || fail "count local small collections"
DST_COUNTS=$(counts "$RURI" remote) || fail "count 115 small collections"
log "counts local: $(printf '%s ' $SRC_COUNTS)"
log "counts 115:   $(printf '%s ' $DST_COUNTS)"
[ "$SRC_COUNTS" = "$DST_COUNTS" ] || fail "small collection counts differ"

# ---- 4) 115 磁盘只告警、不删数据（10 月已两次写满）----
USAGE=$(ssh "${SSH_OPTS[@]}" root@"$HOST" "df / | awk 'NR==2{gsub(\"%\",\"\",\$5); print \$5}'" || true)
if [ -n "$USAGE" ]; then
  log "115 / disk usage: ${USAGE}%"
  if [ "$USAGE" -ge 85 ]; then
    "$NOTIFY" "115 磁盘告警" "sync_realtime_to_115: / 已用 ${USAGE}%，请清理镜像/日志" >/dev/null 2>&1 || true
  fi
fi

log "done"
