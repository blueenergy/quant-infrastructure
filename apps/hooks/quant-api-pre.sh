#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."   # apps/

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] [quant-api-pre] $*"; }

COMPOSE=(docker compose --env-file versions.env)

run_index_tool() {
  local timeout_seconds="$1"
  shift

  timeout "$timeout_seconds" "${COMPOSE[@]}" run --rm --no-deps quant-api "$@"
}

log "Pulling quant-api image for pre-deploy maintenance"
"${COMPOSE[@]}" pull quant-api

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
