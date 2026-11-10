#!/usr/bin/env bash
# Run one Phase 0 assistant brief from the released ACR image.
#
# The assistant is a scheduled one-shot, not a long-running compose service:
# CI builds/pushes the image and bumps QUANT_ASSISTANT_IMAGE_TAG; this script
# reads that tag on each run, so the host picks up a new image without a
# deploy dispatch.
#
# Cron (local WSL; use `bash`, not direct execution — core.fileMode=false
# strips the exec bit in this repo):
#   0 8 * * 1-5  bash /home/shuyolin/trading/quant-infrastructure/host/assistant_brief.sh morning >> /home/shuyolin/trading/logs/assistant_brief.log 2>&1
#   27 9 * * 1-5 bash /home/shuyolin/trading/quant-infrastructure/host/assistant_brief.sh auction >> /home/shuyolin/trading/logs/assistant_brief.log 2>&1
#     (27 分，等 09:26:12 的完整特征落库；09:26:01 会读到 partial 行)
#   40 16 * * 1-5 bash /home/shuyolin/trading/quant-infrastructure/host/assistant_brief.sh close  >> /home/shuyolin/trading/logs/assistant_brief.log 2>&1
set -euo pipefail

REPO="${REPO:-/home/shuyolin/trading/quant-infrastructure}"
WORKFLOW="${1:-morning}"
case "$WORKFLOW" in
  morning|auction|close) ;;
  *) echo "usage: $0 [morning|auction|close]" >&2; exit 2 ;;
esac

VERSIONS="$REPO/apps/versions.env"
ENV_FILE="$REPO/apps/env/quant-assistant.env"
COMMON_ENV="$REPO/apps/env/common.env"
OUTPUT_DIR="${ASSISTANT_OUTPUT_DIR:-/home/shuyolin/trading/agent-runs}"
IMAGE_REPO="crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com/wukongquant/quant-assistant"

log() { echo "[$(date '+%F %T')] $*"; }

for path in "$VERSIONS" "$ENV_FILE" "$COMMON_ENV"; do
  [ -f "$path" ] || { log "ERROR: missing $path"; exit 1; }
done

TAG="$(grep -E '^QUANT_ASSISTANT_IMAGE_TAG=' "$VERSIONS" | tail -1 | cut -d= -f2- || true)"
[ -n "$TAG" ] || { log "ERROR: QUANT_ASSISTANT_IMAGE_TAG missing in $VERSIONS"; exit 1; }
IMAGE="$IMAGE_REPO:$TAG"

LOCK=/tmp/assistant_brief.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  log "Another assistant brief is running; skipping."
  exit 0
fi

mkdir -p "$OUTPUT_DIR" /home/shuyolin/trading/logs
log "assistant $WORKFLOW start image=$IMAGE"
docker pull "$IMAGE"
docker run --rm \
  --network quant-network \
  --user "$(id -u):$(id -g)" \
  --env-file "$COMMON_ENV" \
  --env-file "$ENV_FILE" \
  -e ASSISTANT_OUTPUT_DIR=/out \
  -v "$OUTPUT_DIR:/out" \
  --log-driver json-file \
  --log-opt max-size=50m \
  --log-opt max-file=3 \
  "$IMAGE" "$WORKFLOW"
log "assistant $WORKFLOW done"
