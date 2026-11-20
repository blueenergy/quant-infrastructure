#!/usr/bin/env bash
# Post-deploy hook for quant-scorer.
# Mirrors the `portfolio-db-maintenance` job from the old CI pipeline:
#   seed_portfolio_param_presets — seed default parameter presets
#
# The index-creation step (ensure_portfolio_indexes.py) is gone: quant-scorer
# archived that tool and .dockerignore deliberately excludes archive/, so the
# call could never resolve. Portfolio indexes are maintained at runtime by
# portfolio.db.ensure_trading_indexes in the daily enqueue job, and the live
# collections already carry them.
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
    --network quant-network \
    --add-host=host.docker.internal:host-gateway \
    --env-file env/common.env \
    --env-file env/quant-scorer.env \
    -e TZ=Asia/Shanghai \
    "$IMAGE" \
    "$@"
}

# MONGO_URI in common.env uses the compose service hostname quant-mongodb,
# which only resolves on the shared Docker network (same as quant-api-pre.sh).
log "Ensuring shared Docker network"
docker network inspect quant-network >/dev/null 2>&1 || docker network create quant-network

log "Seeding portfolio parameter presets"
run_tool python tools/ops/seed_portfolio_param_presets.py --apply

log "Portfolio database maintenance finished"
