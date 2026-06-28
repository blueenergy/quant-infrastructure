#!/usr/bin/env bash
# ============================================================================
# deploy.sh — Roll out the application stack on the production host.
#
# This is the CD entrypoint executed ON the production server (invoked by the
# infra GitHub Actions workflow over SSH, or manually). It treats
# `versions.env` (image tags) + `docker-compose.yml` as the desired state and
# converges the host to it.
#
# Usage:
#   ./deploy.sh                       # deploy ALL services in the compose file
#   ./deploy.sh quant-data-engine     # deploy only the given service(s)
#   ./deploy.sh quant-api quant-web   # deploy several services
#
# Required env (for pulling from the private Aliyun registry):
#   ALIYUN_USER, ALIYUN_TOKEN
#
# Optional env:
#   ACR_REGISTRY  (default: crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com)
#   COMPOSE_WAIT  (default: 1 -> pass --wait to `up`)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ACR_REGISTRY="${ACR_REGISTRY:-crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com}"
COMPOSE_WAIT="${COMPOSE_WAIT:-1}"
SERVICES=("$@")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; }

# Image tags are interpolated from versions.env. Runtime config/secrets are
# injected per service via `env_file:` (env/common.env + env/<svc>.env) in the
# compose file, so they don't need to be passed here.
COMPOSE=(docker compose --env-file versions.env)

require_files() {
  for f in docker-compose.yml versions.env; do
    if [ ! -f "$f" ]; then
      echo "ERROR: required file '$f' not found in $SCRIPT_DIR" >&2
      exit 1
    fi
  done
  # Note: compose still requires every service's env_file to exist on disk
  # (incl. legacy `.env` for not-yet-migrated services). It will error clearly
  # if one is missing.
}

acr_login() {
  if [ -n "${ALIYUN_USER:-}" ] && [ -n "${ALIYUN_TOKEN:-}" ]; then
    log "Logging in to Aliyun registry ($ACR_REGISTRY)"
    echo "$ALIYUN_TOKEN" | timeout 60 docker login "$ACR_REGISTRY" -u "$ALIYUN_USER" --password-stdin
  else
    log "ALIYUN_USER/ALIYUN_TOKEN not set; assuming host is already logged in"
  fi
}

# Per-service hooks: apps/hooks/<service>-pre.sh and <service>-post.sh.
# Used e.g. for quant-api DB index migrations. Hooks receive the resolved
# image reference as $1 and run with the same env as this script.
run_hook() {
  local phase="$1" svc="$2"
  local hook="$SCRIPT_DIR/hooks/${svc}-${phase}.sh"
  if [ -x "$hook" ]; then
    log "Running ${phase} hook for ${svc}: $hook"
    "$hook" || { echo "ERROR: ${phase} hook for ${svc} failed" >&2; exit 1; }
  fi
}

main() {
  require_files
  acr_login

  local up_flags=(-d --remove-orphans)
  if [ "$COMPOSE_WAIT" = "1" ]; then
    up_flags+=(--wait)
  fi

  # Build --scale flags from *_REPLICAS entries in versions.env, filtered to
  # only the services being deployed. Passing --scale for a service not in the
  # target list causes compose to error, so we scope flags to the target set
  # (empty target = all services = include every scale flag).
  # e.g. QUANT_ANALYZER_REPLICAS=4  →  --scale quant-analyzer=4
  build_scale_flags() {
    local -a targets=("$@")   # empty = deploy all → include all scale flags
    grep -E '^[A-Z_]+_REPLICAS=[0-9]+' versions.env 2>/dev/null \
    | while IFS='=' read -r key val; do
        local svc="${key%_REPLICAS}"
        svc="${svc,,}"
        svc="${svc//_/-}"
        # Include if deploying all, or if this service is explicitly targeted.
        if [ "${#targets[@]}" -eq 0 ]; then
          echo "--scale=${svc}=${val}"
        else
          for t in "${targets[@]}"; do
            [ "$t" = "$svc" ] && echo "--scale=${svc}=${val}" && break
          done
        fi
      done
  }

  if [ "${#SERVICES[@]}" -eq 0 ]; then
    mapfile -t SCALE_FLAGS < <(build_scale_flags)
    [ "${#SCALE_FLAGS[@]}" -gt 0 ] && log "Scale flags: ${SCALE_FLAGS[*]}"
    log "Pulling all service images"
    "${COMPOSE[@]}" pull
    log "Bringing up all services"
    "${COMPOSE[@]}" up "${up_flags[@]}" "${SCALE_FLAGS[@]}"
  else
    mapfile -t SCALE_FLAGS < <(build_scale_flags "${SERVICES[@]}")
    [ "${#SCALE_FLAGS[@]}" -gt 0 ] && log "Scale flags: ${SCALE_FLAGS[*]}"
    log "Target services: ${SERVICES[*]}"
    for svc in "${SERVICES[@]}"; do
      run_hook pre "$svc"
    done
    log "Pulling images for: ${SERVICES[*]}"
    "${COMPOSE[@]}" pull "${SERVICES[@]}"
    log "Bringing up: ${SERVICES[*]}"
    # --no-deps so we never restart unrelated services during a targeted roll.
    "${COMPOSE[@]}" up "${up_flags[@]}" --no-deps "${SCALE_FLAGS[@]}" "${SERVICES[@]}"
    for svc in "${SERVICES[@]}"; do
      run_hook post "$svc"
    done
  fi

  log "Deployed containers:"
  "${COMPOSE[@]}" ps

  log "Pruning dangling images"
  timeout 120 docker image prune -f || true

  log "Deploy finished"
}

main "$@"
