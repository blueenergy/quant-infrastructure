#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."   # apps/

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] [quant-api-pre] $*"; }

ACR_REGISTRY="${ACR_REGISTRY:-crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com}"
QUANT_API_IMAGE_TAG="$(grep '^QUANT_API_IMAGE_TAG=' versions.env | cut -d= -f2-)"
IMAGE="${ACR_REGISTRY}/wukongquant/quant-api:${QUANT_API_IMAGE_TAG:-latest}"

run_index_tool() {
  local timeout_seconds="$1"
  shift

  timeout "$timeout_seconds" docker run --rm \
    --network quant-network \
    --add-host=host.docker.internal:host-gateway \
    --env-file env/quant-api.env \
    -e TZ=Asia/Shanghai \
    "$IMAGE" \
    "$@"
}

log "Ensuring shared Docker network"
docker network inspect quant-network >/dev/null 2>&1 || docker network create quant-network

log "Pulling quant-api image for pre-deploy maintenance: $IMAGE"
timeout 300 docker pull "$IMAGE"

log "Ensuring portfolio plan MongoDB indexes"
run_index_tool 120 python tools/check_portfolio_plan_indexes.py --apply \
  || log "WARN: portfolio index maintenance failed (continuing deploy)"

log "Ensuring general performance MongoDB indexes"
run_index_tool 600 python tools/check_and_fix_indexes.py --apply \
  || log "WARN: general index maintenance failed (continuing deploy)"

# First compose-managed rollout must remove any legacy docker-run containers
# with the same names; otherwise docker compose cannot create container_name
# targets. This remains safe on later deploys because compose recreates them in
# the following up step.
for container in quant-mcp-actions quant-mcp-read quant-mcp quant-scheduler quant-api; do
  log "Removing legacy/existing container if present: $container"
  timeout 30 docker stop -t 20 "$container" 2>/dev/null || true
  timeout 30 docker rm "$container" 2>/dev/null || true
done

log "Pre-deploy maintenance finished"
