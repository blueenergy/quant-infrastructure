#!/usr/bin/env bash
# Post-deploy hook for quant-scorer.
#
# Scoring-only: portfolio database maintenance (parameter-preset seeding,
# index creation) moved with the portfolio service when quant-scorer was
# reduced to scoring. The only host-level step left is ensuring the shared
# Docker network exists.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."   # apps/

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] [quant-scorer-post] $*"; }

log "Ensuring shared Docker network"
docker network inspect quant-network >/dev/null 2>&1 || docker network create quant-network

log "quant-scorer post-deploy finished"
