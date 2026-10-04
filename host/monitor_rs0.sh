#!/bin/bash
# MongoDB rs0 健康监控（host cron 每 5 分钟）
#
# 检查项（逐项收集，不做短路）：
#   1. host 上 27017 端口有监听（mirrored 模式下由 docker-proxy 发布）
#   2. quant-mongodb 容器 healthcheck = healthy
#   3. mongod 是 PRIMARY（isWritablePrimary）—— 覆盖 REMOVED / 非主状态
#   4. Mac secondary(192.168.3.5) 心跳健康、optime 滞后、是否掉出 oplog 窗口
#
# 告警：钉钉机器人（与数据合约告警共用，加签模式），只在状态翻转时发送；
#       持续异常每 RE_ALERT_SEC 补发一次；未配置 webhook 时只写日志。
# 状态文件 /tmp/monitor_rs0.state：WSL 重启即清空 → 开机首跑若异常立刻告警。
set -u

REPO=/home/shuyolin/trading/quant-infrastructure
LOG=$REPO/monitor_rs0.log
STATE=/tmp/monitor_rs0.state
ENV_FILE=$REPO/host/.env.monitor
LOCK=/tmp/monitor_rs0.lock
CONT=quant-mongodb
SITE=${SITE:-$(hostname)}

LAG_WARN_SEC=${LAG_WARN_SEC:-60}
RE_ALERT_SEC=${RE_ALERT_SEC:-21600}   # 持续异常时每 6h 补发

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  flock -n 9 || { log "Another run is active; skipping."; exit 0; }
fi

DINGTALK_WEBHOOK_URL=""
DINGTALK_WEBHOOK_SECRET=""
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090  # gitignored secret file
  . "$ENV_FILE"
fi

have_webhook() {
  [ -n "${DINGTALK_WEBHOOK_URL:-}" ] && [ "$DINGTALK_WEBHOOK_URL" != "<填这里>" ]
}

# ── 钉钉通知（加签模式，算法同 quant-data-engine notifier.py._signed_url）──
send_dingtalk() {
  local title="$1" content="$2" ts sign payload resp body code
  if ! have_webhook; then
    log "NOTIFY(skipped, webhook 未配置): $title | $content"
    return 0
  fi
  ts=$(( $(date +%s) * 1000 ))
  # sign = urlencode(base64(HMAC-SHA256(secret, "ts\nsecret")))
  # base64 字母表不含 %，sed 替换无歧义
  sign=$(printf '%s\n%s' "$ts" "$DINGTALK_WEBHOOK_SECRET" \
    | openssl dgst -sha256 -hmac "$DINGTALK_WEBHOOK_SECRET" -binary \
    | base64 | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
  payload="{\"msgtype\":\"text\",\"text\":{\"content\":\"[Mongo rs0 监控] $SITE $title\n$content\"}}"
  resp=$(curl -s -m 15 -w $'\n%{http_code}' -X POST \
    "$DINGTALK_WEBHOOK_URL&timestamp=${ts}&sign=${sign}" \
    -H 'Content-Type: application/json' --data "$payload" 2>&1)
  body=${resp%$'\n'*}
  code=${resp##*$'\n'}
  if [ "$code" != "200" ]; then
    log "NOTIFY failed: http=$code body=$body"
    return 1
  fi
  # 钉钉拒绝时也返回 200，错误在 body 的 errcode
  errcode=$(printf '%s' "$body" | sed -n 's/.*"errcode":\([-0-9]*\).*/\1/p')
  if [ -n "$errcode" ] && [ "$errcode" != "0" ]; then
    log "NOTIFY rejected: errcode=$errcode body=$body"
    return 1
  fi
  log "NOTIFY sent: $title"
}

# ── 检查项 ────────────────────────────────────────────────────────────────
port_ok() { ss -tln 2>/dev/null | grep -q ':27017 '; }

container_healthy() {
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$CONT" 2>/dev/null)" = "healthy" ]
}

# mongosh 单行输出: METRICS|writable|secHealth|secState|lagSec|windowSec
# 失败时输出错误文本，由调用方判解析失败。
mongo_metrics() {
  local js='const st = rs.status();
const me = st.members.find(m => m.name.indexOf("192.168.3.9") === 0);
const sec = st.members.find(m => m.name.indexOf("192.168.3.5") === 0);
const w = db.hello().isWritablePrimary;
const lag = (me && me.optimeDate && sec && sec.optimeDate) ? Math.round((me.optimeDate - sec.optimeDate) / 1000) : -1;
const first = db.getSiblingDB("local").oplog.rs.find({}, {ts:1}).sort({ts:1}).limit(1).tryNext();
const windowSec = (me.optimeDate && first) ? Math.round((me.optimeDate - new Date(first.ts.getHighBits() * 1000)) / 1000) : -1;
print("METRICS|" + [w ? "true" : "false", sec ? sec.health : -1, sec ? sec.stateStr : "NONE", lag, windowSec].join("|"));'
  # print 之后 mongosh 还会补一个空提示符行，用 METRICS| 前缀 + tail 精确定位
  printf '%s\n' "$js" | docker exec -i "$CONT" sh -c \
    'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin' \
    2>&1 | grep 'METRICS|' | tail -n 1 | sed 's/^.*METRICS|//'
}

# ── 主流程 ────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  send_dingtalk "自检" "监控脚本 self-test（手动触发），通道与加签正常。"
  exit 0
fi

bad=""
ok_summary=""
append_bad() { bad="${bad}${bad:+；}$1"; }

if port_ok; then ok_summary+="port=ok "; else append_bad "27017 端口无监听（docker-proxy 未发布）"; fi
if container_healthy; then ok_summary+="container=ok "; else append_bad "mongodb 容器不健康"; fi

mongo_out=$(mongo_metrics)
IFS='|' read -r writable sec_health sec_state lag_sec window_sec <<< "$mongo_out"

case "$writable" in
  true)  ok_summary+="primary=ok " ;;
  false) append_bad "mongod 不是 PRIMARY（疑似 REMOVED/选举失败）" ;;
  *)     append_bad "rs.status() 查询失败: ${mongo_out:0:120}" ;;
esac

if [ "$writable" = "true" ] || [ "$writable" = "false" ]; then
  if [ "$sec_health" != "1" ] || { [ "$sec_health" = "1" ] && [ "$sec_state" = "NONE" ]; }; then
    append_bad "Mac secondary health=${sec_health} state=${sec_state}"
  elif [ "$lag_sec" -gt "$LAG_WARN_SEC" ] 2>/dev/null; then
    if [ "$window_sec" -gt 0 ] 2>/dev/null && [ "$lag_sec" -gt "$window_sec" ]; then
      append_bad "Mac 滞后 ${lag_sec}s > oplog 窗口 ${window_sec}s，无法增量追平，需重新初始同步"
    else
      append_bad "Mac 滞后 ${lag_sec}s（阈值 ${LAG_WARN_SEC}s）"
    fi
  else
    ok_summary+="lag=${lag_sec}s "
  fi
fi

status=OK; [ -n "$bad" ] && status=BAD

# ── 状态翻转与补发 ────────────────────────────────────────────────────────
LAST_STATUS=UNKNOWN; LAST_ALERT=0; LAST_BAD=""
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  . "$STATE"
fi
# last_bad 可能含空格/中文，必须引号包裹，否则 source 回去会被拆成单词
printf 'LAST_STATUS=%s\nLAST_ALERT=%s\nLAST_BAD="%s"\n' \
  "$status" "${LAST_ALERT:-0}" "$bad" > "$STATE"

now=$(date +%s)
if [ "$status" = "BAD" ]; then
  if [ "$LAST_STATUS" != "BAD" ] || [ $(( now - LAST_ALERT )) -ge "$RE_ALERT_SEC" ]; then
    send_dingtalk "异常" "$bad"
    sed -i "s/^LAST_ALERT=.*/LAST_ALERT=$now/" "$STATE"
  fi
elif [ "$LAST_STATUS" = "BAD" ]; then
  send_dingtalk "已恢复" "之前异常: ${LAST_BAD:-未知}"
  sed -i "s/^LAST_ALERT=.*/LAST_ALERT=0/" "$STATE"
fi

log "status=$status $ok_summary${bad:+[bad: $bad]}"
exit 0