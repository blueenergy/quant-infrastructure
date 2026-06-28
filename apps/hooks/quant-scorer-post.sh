#!/usr/bin/env bash
# Post-deploy hook for quant-scorer.
# Mirrors the `portfolio-db-maintenance` job from the old CI pipeline:
#   1. ensure_portfolio_indexes  — idempotent index creation / migration
#   2. seed_portfolio_param_presets — seed default parameter presets
#
# Runs from apps/ directory (set by deploy.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."   # apps/

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] [quant-scorer-post] $*"; }

# Resolve the exact image tag from versions.env so we always run maintenance
# against the same image that was just deployed.
QUANT_SCORER_IMAGE_TAG="$(grep '^QUANT_SCORER_IMAGE_TAG=' versions.env | cut -d= -f2-)"
IMAGE="crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com/wukongquant/quant-scorer:${QUANT_SCORER_IMAGE_TAG:-latest}"

run_tool() {
  timeout 120 docker run --rm \
    --add-host=host.docker.internal:host-gateway \
    --env-file env/common.env \
    --env-file env/quant-scorer.env \
    -e TZ=Asia/Shanghai \
    "$IMAGE" \
    "$@"
}

log "Ensuring portfolio indexes (image: $IMAGE)"
run_tool python tools/ensure_portfolio_indexes.py

log "Seeding portfolio parameter presets"
run_tool python tools/seed_portfolio_param_presets.py --apply

log "Portfolio database maintenance finished"
