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
if [ -f docker-compose.115.yml ] && [ "$(_common_env_get COMPOSE_HOST_PROFILE)" = "115" ]; then
  COMPOSE+=( -f docker-compose.115.yml )
fi

# Read KEY=value from env/common.env without sourcing the whole secrets file.
_common_env_get() {
  local key="$1"
  local file="$SCRIPT_DIR/env/common.env"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

# Derive opt-in profiles for services that can run either on this Compose host
# or in Kubernetes. Both runtimes default to local_docker for compatibility.
resolve_local_runtime_profiles() {
  if [ -n "${COMPOSE_PROFILES+x}" ] && [ -n "${COMPOSE_PROFILES}" ]; then
    export COMPOSE_PROFILES
    log "COMPOSE_PROFILES already set: ${COMPOSE_PROFILES}"
    return 0
  fi

  local research_runtime factor_backtest_runtime scorer_runtime portfolio_runtime data_engine_runtime backtest_runtime analyzer_runtime configured_profiles
  local -a profiles=()
  research_runtime="$(_common_env_get PORTFOLIO_RESEARCH_RUNTIME)"
  factor_backtest_runtime="$(_common_env_get FACTOR_BACKTEST_RUNTIME)"
  scorer_runtime="$(_common_env_get QUANT_SCORER_RUNTIME)"
  portfolio_runtime="$(_common_env_get QUANT_PORTFOLIO_RUNTIME)"
  data_engine_runtime="$(_common_env_get QUANT_DATA_ENGINE_RUNTIME)"
  backtest_runtime="$(_common_env_get BACKTEST_WORKER_RUNTIME)"
  analyzer_runtime="$(_common_env_get QUANT_ANALYZER_RUNTIME)"
  configured_profiles="$(_common_env_get COMPOSE_PROFILES)"
  research_runtime="${research_runtime:-local_docker}"
  factor_backtest_runtime="${factor_backtest_runtime:-local_docker}"
  scorer_runtime="${scorer_runtime:-local_docker}"
  portfolio_runtime="${portfolio_runtime:-local_docker}"
  data_engine_runtime="${data_engine_runtime:-local_docker}"
  backtest_runtime="${backtest_runtime:-local_docker}"
  analyzer_runtime="${analyzer_runtime:-local_docker}"

  if [ -n "$configured_profiles" ]; then
    export COMPOSE_PROFILES="$configured_profiles"
  else
    [ "$research_runtime" = "local_docker" ] && profiles+=("research-local")
    [ "$factor_backtest_runtime" = "local_docker" ] && profiles+=("factor-research-local")
    [ "$scorer_runtime" = "local_docker" ] && profiles+=("scorer-local")
    [ "$portfolio_runtime" = "local_docker" ] && profiles+=("portfolio-local")
    [ "$data_engine_runtime" = "local_docker" ] && profiles+=("data-engine-local")
    [ "$backtest_runtime" = "local_docker" ] && profiles+=("backtest-local")
    [ "$analyzer_runtime" = "local_docker" ] && profiles+=("analyzer-local")
    local IFS=,
    export COMPOSE_PROFILES="${profiles[*]}"
  fi
  log "PORTFOLIO_RESEARCH_RUNTIME=${research_runtime} FACTOR_BACKTEST_RUNTIME=${factor_backtest_runtime} QUANT_SCORER_RUNTIME=${scorer_runtime} QUANT_PORTFOLIO_RUNTIME=${portfolio_runtime} QUANT_DATA_ENGINE_RUNTIME=${data_engine_runtime} BACKTEST_WORKER_RUNTIME=${backtest_runtime} QUANT_ANALYZER_RUNTIME=${analyzer_runtime} COMPOSE_PROFILES=${COMPOSE_PROFILES:-<empty>}"
}

_service_external_k8s() {
  local svc="$1"
  local runtime
  case "$svc" in
    quant-researcher) runtime="$(_common_env_get PORTFOLIO_RESEARCH_RUNTIME)" ;;
    quant-factor-researcher) runtime="$(_common_env_get FACTOR_BACKTEST_RUNTIME)" ;;
    quant-scorer) runtime="$(_common_env_get QUANT_SCORER_RUNTIME)" ;;
    quant-portfolio) runtime="$(_common_env_get QUANT_PORTFOLIO_RUNTIME)" ;;
    quant-data-engine) runtime="$(_common_env_get QUANT_DATA_ENGINE_RUNTIME)" ;;
    backtest-worker|backtest-screening) runtime="$(_common_env_get BACKTEST_WORKER_RUNTIME)" ;;
    quant-analyzer) runtime="$(_common_env_get QUANT_ANALYZER_RUNTIME)" ;;
    *) return 1 ;;
  esac
  runtime="${runtime:-local_docker}"
  [ "$runtime" = "external_k8s" ]
}

_service_compose_profile() {
  local svc="$1"
  case "$svc" in
    quant-researcher) echo "research-local" ;;
    quant-factor-researcher) echo "factor-research-local" ;;
    quant-scorer) echo "scorer-local" ;;
    quant-portfolio) echo "portfolio-local" ;;
    quant-data-engine) echo "data-engine-local" ;;
    backtest-worker|backtest-screening) echo "backtest-local" ;;
    quant-analyzer) echo "analyzer-local" ;;
    *) return 1 ;;
  esac
}

_runtime_env_key_for_service() {
  local svc="$1"
  case "$svc" in
    quant-researcher) echo "PORTFOLIO_RESEARCH_RUNTIME" ;;
    quant-factor-researcher) echo "FACTOR_BACKTEST_RUNTIME" ;;
    quant-scorer) echo "QUANT_SCORER_RUNTIME" ;;
    quant-portfolio) echo "QUANT_PORTFOLIO_RUNTIME" ;;
    quant-data-engine) echo "QUANT_DATA_ENGINE_RUNTIME" ;;
    backtest-worker|backtest-screening) echo "BACKTEST_WORKER_RUNTIME" ;;
    quant-analyzer) echo "QUANT_ANALYZER_RUNTIME" ;;
    *) return 1 ;;
  esac
}

filter_services_for_external_runtimes() {
  local -a kept=()
  local svc
  for svc in "${SERVICES[@]}"; do
    if _service_external_k8s "$svc"; then
      log "Skipping $svc ($(_runtime_env_key_for_service "$svc")=external_k8s)"
      continue
    fi
    kept+=("$svc")
  done
  SERVICES=("${kept[@]}")
}

stop_local_services_for_external_runtimes() {
  local svc profile runtime_key any_external=0
  for svc in quant-researcher quant-scorer quant-portfolio quant-data-engine backtest-worker backtest-screening quant-analyzer; do
    if _service_external_k8s "$svc"; then
      any_external=1
      profile="$(_service_compose_profile "$svc")"
      runtime_key="$(_runtime_env_key_for_service "$svc")"
      log "Stopping local $svc (${runtime_key}=external_k8s)"
      "${COMPOSE[@]}" --profile "$profile" stop "$svc" 2>/dev/null || true
      "${COMPOSE[@]}" --profile "$profile" rm -f "$svc" 2>/dev/null || true
    fi
  done

  if [ "$any_external" -eq 1 ]; then
    log "External K8s roles are deployed separately from an FCI-connected host"
  fi
}

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
  resolve_local_runtime_profiles
  if [ -f docker-compose.115.yml ] && [ "$(_common_env_get COMPOSE_HOST_PROFILE)" = "115" ]; then
    log "COMPOSE_HOST_PROFILE=115: using docker-compose.115.yml memory limits"
  fi
  stop_local_services_for_external_runtimes

  local explicit_services=0
  if [ "${#SERVICES[@]}" -gt 0 ]; then
    explicit_services=1
  fi
  filter_services_for_external_runtimes
  if [ "$explicit_services" -eq 1 ] && [ "${#SERVICES[@]}" -eq 0 ]; then
    log "No services left to deploy after research-runtime filter"
    return 0
  fi

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
