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
#   IMAGE_KEEP_HOURS (default: 12 -> how long a superseded image stays on disk
#                    as a rollback target before the post-deploy prune drops it)
#   IMAGE_KEEP_LAST_N (default: 2 -> keep at most the newest N release images
#                    per repo; caps same-day build churn even inside the window)
#   IMAGE_MIN_AGE_HOURS (default: 1 -> never prune an image younger than this,
#                    so a concurrent deploy cannot lose the image it just pulled)
#   DISK_ALERT_PCT   (default: 85 -> warn when / is at or above this after the
#                    prune. 2026-10-16: this host filled to 100%, every deploy
#                    died at `git fetch`, and the only signal was a green log)
#
# MCP (quant-mcp-read / quant-mcp-actions) uses Compose profile `mcp`.
# deploy.sh enables it by default except COMPOSE_HOST_PROFILE=115.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ACR_REGISTRY="${ACR_REGISTRY:-crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com}"
COMPOSE_WAIT="${COMPOSE_WAIT:-1}"
IMAGE_KEEP_HOURS="${IMAGE_KEEP_HOURS:-12}"
IMAGE_KEEP_LAST_N="${IMAGE_KEEP_LAST_N:-2}"
IMAGE_MIN_AGE_HOURS="${IMAGE_MIN_AGE_HOURS:-1}"
DISK_ALERT_PCT="${DISK_ALERT_PCT:-85}"
SERVICES=()

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"; }

# One sentence, two lines: the plain one is what auto_update.log keeps on the
# local cron path, the `::warning` one is what GitHub renders as an annotation
# (the runner parses workflow commands out of the step's stdout, SSH included).
#
# A warning is deliberately NOT a non-zero exit. By the time either of these
# fires the rollout has already succeeded, and failing the job here would page
# the same DingTalk robot with "deploy failed" -- a lie about what the host did.
warn() { log "WARN: $2"; echo "::warning title=$1::$2"; }

# Read KEY=value from env/common.env without sourcing the whole secrets file.
# Must stay above the COMPOSE assignment below, which calls it.
_common_env_get() {
  local key="$1"
  local file="${DEPLOY_COMMON_ENV:-$SCRIPT_DIR/env/common.env}"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

_host_is_115() {
  [ "$(_common_env_get COMPOSE_HOST_PROFILE)" = "115" ]
}

# Trim spaces and test whether a comma-separated profile list contains needle.
_csv_has_profile() {
  local needle="$1"
  local csv="${2:-}"
  local item
  local IFS=','
  local -a items
  read -ra items <<< "$csv"
  for item in "${items[@]}"; do
    item="${item// /}"
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

_csv_without_profile() {
  local needle="$1"
  local csv="${2:-}"
  local item
  local -a kept=()
  local IFS=','
  local -a items
  read -ra items <<< "$csv"
  for item in "${items[@]}"; do
    item="${item// /}"
    [ -z "$item" ] && continue
    [ "$item" = "$needle" ] && continue
    kept+=("$item")
  done
  local IFS=,
  echo "${kept[*]}"
}

_is_mcp_service() {
  case "$1" in
    quant-mcp-read|quant-mcp-actions) return 0 ;;
    *) return 1 ;;
  esac
}

_append_service_if_missing() {
  local svc="$1"
  local existing
  for existing in "${SERVICES[@]+"${SERVICES[@]}"}"; do
    [ "$existing" = "$svc" ] && return 0
  done
  SERVICES+=("$svc")
  log "Including $svc (shares QUANT_API_IMAGE_TAG; mcp profile default-on)"
}

# MCP containers stay behind Compose profile "mcp". Enable it on every host
# except COMPOSE_HOST_PROFILE=115 (8GB + Mongo Primary). A hand-written mcp
# entry in COMPOSE_PROFILES is also stripped on 115.
apply_mcp_profile() {
  local profiles="${COMPOSE_PROFILES:-}"
  if _host_is_115; then
    if _csv_has_profile mcp "$profiles"; then
      log "COMPOSE_HOST_PROFILE=115: dropping mcp profile (MCP stays off)"
      COMPOSE_PROFILES="$(_csv_without_profile mcp "$profiles")"
      export COMPOSE_PROFILES
    fi
    return 0
  fi
  if ! _csv_has_profile mcp "$profiles"; then
    if [ -n "$profiles" ]; then
      COMPOSE_PROFILES="${profiles},mcp"
    else
      COMPOSE_PROFILES="mcp"
    fi
    export COMPOSE_PROFILES
    log "Enabled mcp profile (COMPOSE_HOST_PROFILE is not 115)"
  fi
}

# Non-115 quant-api / scheduler rolls must recreate MCP: they share the API
# image, and quant-api-pre.sh stop/rm's the MCP container names.
expand_mcp_services() {
  _host_is_115 && return 0
  [ "${#SERVICES[@]}" -eq 0 ] && return 0
  local wants_mcp=0 svc
  for svc in "${SERVICES[@]}"; do
    case "$svc" in
      quant-api|quant-scheduler|quant-mcp-read|quant-mcp-actions) wants_mcp=1 ;;
    esac
  done
  [ "$wants_mcp" = 1 ] || return 0
  _append_service_if_missing quant-mcp-read
  _append_service_if_missing quant-mcp-actions
}

filter_mcp_services_on_115() {
  _host_is_115 || return 0
  [ "${#SERVICES[@]}" -eq 0 ] && return 0
  local svc
  local -a kept=()
  for svc in "${SERVICES[@]}"; do
    if _is_mcp_service "$svc"; then
      log "Skipping $svc (COMPOSE_HOST_PROFILE=115; MCP stays off)"
      continue
    fi
    kept+=("$svc")
  done
  SERVICES=("${kept[@]+"${kept[@]}"}")
}

stop_mcp_on_115() {
  _host_is_115 || return 0
  log "COMPOSE_HOST_PROFILE=115: ensuring MCP containers are stopped"
  "${COMPOSE[@]}" --profile mcp stop quant-mcp-read quant-mcp-actions 2>/dev/null || true
  "${COMPOSE[@]}" --profile mcp rm -f quant-mcp-read quant-mcp-actions 2>/dev/null || true
}

# 115 is a minimal edge node: quant-web + quant-api + quant-data-engine + Mongo
# + Portainer, nothing else. Default-deny, not a one-time cleanup: a new
# service, a CI dispatch for a worker, or a bare `./deploy.sh` (which used to
# mean "up the whole stack") must never bring anything else back. The heavier
# workers live in K8s / the local WSL host; see docker-compose.115.yml for the
# corresponding memory-limit trim.
ALLOWED_SERVICES_ON_115=(quant-api quant-web quant-data-engine)
# Containers from other compose projects that must not run on this host.
FORBIDDEN_CONTAINERS_ON_115=(quant-assistant)

_is_allowed_service_on_115() {
  local svc="$1" allowed
  for allowed in "${ALLOWED_SERVICES_ON_115[@]}"; do
    [ "$svc" = "$allowed" ] && return 0
  done
  return 1
}

filter_services_on_115() {
  _host_is_115 || return 0
  if [ "${#SERVICES[@]}" -eq 0 ]; then
    SERVICES=("${ALLOWED_SERVICES_ON_115[@]}")
    log "COMPOSE_HOST_PROFILE=115: no explicit targets; deploying allowlist only (${SERVICES[*]})"
    return 0
  fi
  local svc
  local -a kept=()
  for svc in "${SERVICES[@]}"; do
    if _is_allowed_service_on_115 "$svc"; then
      kept+=("$svc")
    else
      log "Skipping $svc (COMPOSE_HOST_PROFILE=115; not in allowlist: ${ALLOWED_SERVICES_ON_115[*]})"
    fi
  done
  SERVICES=("${kept[@]+"${kept[@]}"}")
}

# Self-healing guard: remove any non-allowlisted container from this checkout's
# compose project, and the explicitly forbidden foreign ones. Match on the
# compose working_dir label rather than the project name, because the name is
# derived from the checkout directory and would change with a rename.
stop_services_not_allowed_on_115() {
  _host_is_115 || return 0
  local name working_dir svc
  while IFS=$'\t' read -r name working_dir svc; do
    [ -n "$name" ] || continue
    [ "$working_dir" = "$SCRIPT_DIR" ] || continue
    _is_allowed_service_on_115 "$svc" && continue
    log "COMPOSE_HOST_PROFILE=115: removing $name (service ${svc:-<unknown>} not in allowlist)"
    docker stop --time 30 "$name" >/dev/null 2>&1 || true
    docker rm -f "$name" >/dev/null 2>&1 || true
  done < <(docker ps -a \
             --format '{{.Names}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Label "com.docker.compose.service"}}')
  for name in "${FORBIDDEN_CONTAINERS_ON_115[@]}"; do
    if docker inspect "$name" >/dev/null 2>&1; then
      log "COMPOSE_HOST_PROFILE=115: removing $name (forbidden on this host)"
      docker stop --time 30 "$name" >/dev/null 2>&1 || true
      docker rm -f "$name" >/dev/null 2>&1 || true
    fi
  done
}

# Image tags are interpolated from versions.env. Runtime config/secrets are
# injected per service via `env_file:` (env/common.env + env/<svc>.env) in the
# compose file, so they don't need to be passed here.
#
# Pass -f docker-compose.yml explicitly: adding only `-f docker-compose.115.yml`
# replaces the default file list, so Compose loads the memory-limit overlay
# (no `image:`) and fails with "has neither an image nor a build context".
COMPOSE=(docker compose --env-file versions.env -f docker-compose.yml)
# Host-specific overlay: COMPOSE_HOST_PROFILE=115 -> docker-compose.115.yml,
# =local -> docker-compose.local.yml. The base file is the shared topology for
# every host, so machine-only paths (e.g. an E: drive) belong in the overlay.
COMPOSE_HOST_PROFILE_VALUE=$(_common_env_get COMPOSE_HOST_PROFILE)
if [ -n "$COMPOSE_HOST_PROFILE_VALUE" ] && [ -f "docker-compose.${COMPOSE_HOST_PROFILE_VALUE}.yml" ]; then
  COMPOSE+=( -f "docker-compose.${COMPOSE_HOST_PROFILE_VALUE}.yml" )
fi

# Derive opt-in profiles for services that can run either on this Compose host
# or in Kubernetes. Both runtimes default to local_docker for compatibility.
resolve_local_runtime_profiles() {
  if [ -n "${COMPOSE_PROFILES+x}" ] && [ -n "${COMPOSE_PROFILES}" ]; then
    export COMPOSE_PROFILES
    log "COMPOSE_PROFILES already set: ${COMPOSE_PROFILES}"
  else
    local research_runtime factor_backtest_runtime model_training_runtime scorer_runtime portfolio_runtime data_engine_runtime backtest_runtime analyzer_runtime configured_profiles
    local -a profiles=()
    research_runtime="$(_common_env_get PORTFOLIO_RESEARCH_RUNTIME)"
    factor_backtest_runtime="$(_common_env_get FACTOR_BACKTEST_RUNTIME)"
    model_training_runtime="$(_common_env_get MODEL_TRAINING_RUNTIME)"
    scorer_runtime="$(_common_env_get QUANT_SCORER_RUNTIME)"
    portfolio_runtime="$(_common_env_get QUANT_PORTFOLIO_RUNTIME)"
    data_engine_runtime="$(_common_env_get QUANT_DATA_ENGINE_RUNTIME)"
    backtest_runtime="$(_common_env_get BACKTEST_WORKER_RUNTIME)"
    analyzer_runtime="$(_common_env_get QUANT_ANALYZER_RUNTIME)"
    configured_profiles="$(_common_env_get COMPOSE_PROFILES)"
    research_runtime="${research_runtime:-local_docker}"
    factor_backtest_runtime="${factor_backtest_runtime:-local_docker}"
    model_training_runtime="${model_training_runtime:-local_docker}"
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
      [ "$model_training_runtime" = "local_docker" ] && profiles+=("model-trainer-local")
      [ "$scorer_runtime" = "local_docker" ] && profiles+=("scorer-local")
      [ "$portfolio_runtime" = "local_docker" ] && profiles+=("portfolio-local")
      [ "$data_engine_runtime" = "local_docker" ] && profiles+=("data-engine-local")
      [ "$backtest_runtime" = "local_docker" ] && profiles+=("backtest-local")
      [ "$analyzer_runtime" = "local_docker" ] && profiles+=("analyzer-local")
      local IFS=,
      export COMPOSE_PROFILES="${profiles[*]}"
    fi
    log "PORTFOLIO_RESEARCH_RUNTIME=${research_runtime} FACTOR_BACKTEST_RUNTIME=${factor_backtest_runtime} MODEL_TRAINING_RUNTIME=${model_training_runtime} QUANT_SCORER_RUNTIME=${scorer_runtime} QUANT_PORTFOLIO_RUNTIME=${portfolio_runtime} QUANT_DATA_ENGINE_RUNTIME=${data_engine_runtime} BACKTEST_WORKER_RUNTIME=${backtest_runtime} QUANT_ANALYZER_RUNTIME=${analyzer_runtime} COMPOSE_PROFILES=${COMPOSE_PROFILES:-<empty>}"
  fi
  apply_mcp_profile
  log "COMPOSE_PROFILES after mcp gate: ${COMPOSE_PROFILES:-<empty>}"
}

_service_external_k8s() {
  local svc="$1"
  local runtime
  case "$svc" in
    quant-researcher) runtime="$(_common_env_get PORTFOLIO_RESEARCH_RUNTIME)" ;;
    quant-factor-researcher) runtime="$(_common_env_get FACTOR_BACKTEST_RUNTIME)" ;;
    quant-model-trainer) runtime="$(_common_env_get MODEL_TRAINING_RUNTIME)" ;;
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
    quant-model-trainer) echo "model-trainer-local" ;;
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
    quant-model-trainer) echo "MODEL_TRAINING_RUNTIME" ;;
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
  for svc in quant-researcher quant-factor-researcher quant-model-trainer quant-scorer quant-portfolio quant-data-engine backtest-worker backtest-screening quant-analyzer; do
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

# Drop superseded release images, keeping a rollback window.
#
# Scoped to ${ACR_REGISTRY}/wukongquant/*:sha-* on purpose. A blanket
# `docker image prune -a` also takes host-built images that merely happen to be
# idle, and this host builds some -- a rebuild there is the 90-minute gamble
# that pushing to ACR exists to avoid. Everything in scope here came off the
# registry, so it can always come off it again; nothing here needs a rebuild.
#
# Three guards, all conservative:
#   - keep the newest IMAGE_KEEP_LAST_N images per repo, so a burst of same-day
#     builds cannot pile up inside the time window
#   - only images older than IMAGE_KEEP_HOURS (the time-based upper bound)
#   - never an image any container references, running *or* stopped, since a
#     stopped container may yet be started back into its image
# The newest N and the time window are both upper bounds: an image is pruned
# when it is past the window OR outside the newest N. A short minimum age
# keeps a concurrent deploy from pruning the image it just pulled.
prune_release_images() {
  local dry_run="${1:-}"
  local cutoff min_cutoff keep_ids
  cutoff="$(date -d "-${IMAGE_KEEP_HOURS} hours" '+%Y-%m-%dT%H:%M:%S')"
  min_cutoff="$(date -d "-${IMAGE_MIN_AGE_HOURS} hours" '+%Y-%m-%dT%H:%M:%S')"
  keep_ids="$(
    docker images --no-trunc \
      --filter "reference=${ACR_REGISTRY}/wukongquant/*:sha-*" \
      --format '{{.ID}}|{{.Repository}}|{{.CreatedAt}}' \
    | sort -t'|' -k2,2 -k3,3r \
    | awk -F'|' -v n="${IMAGE_KEEP_LAST_N}" '{c[$2]++; if (c[$2] <= n) print $1}' \
    | sort -u
  )"

  local referenced foreign_tagged
  referenced="$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u || true)"
  # Removing by tag drops only that tag, so an image that also carries a
  # `:latest` convenience tag is left alone -- that tag is not ours to remove.
  foreign_tagged="$(docker images --no-trunc --format '{{.ID}} {{.Tag}}' \
                      | awk '$2 !~ /^sha-/ {print $1}' | sort -u)"

  local id date time tag in_keep
  local -a doomed=() targets=()
  while read -r id date time _; do
    [ -n "${id:-}" ] || continue
    # Never touch an image younger than the deploy-race grace period.
    [ "${date}T${time}" \< "$min_cutoff" ] || continue
    case "$referenced" in *"$id"*) continue ;; esac
    case "$foreign_tagged" in *"$id"*) continue ;; esac
    # Keep the newest N per repo until it ages past the time window.
    in_keep=0
    case "$keep_ids" in *"$id"*) in_keep=1 ;; esac
    if [ "$in_keep" -eq 1 ] && [ "${date}T${time}" \> "$cutoff" ]; then
      continue
    fi
    doomed+=("$id")
    # Remove by tag, not by image id. Every release carries the ACR tag *and* a
    # ghcr.io relay tag, and `docker rmi <id>` refuses an image "referenced in
    # multiple repositories" without --force. Removing by id therefore reclaimed
    # nothing for exactly those images while the run still logged success -- the
    # same zero-reclaim-while-green failure this function exists to end. The
    # filter above matched only the ACR tag, so the rest are collected here;
    # foreign_tagged has already established they are all sha-* release tags.
    while IFS= read -r tag; do
      [ -n "$tag" ] && targets+=("$tag")
    done < <(docker image inspect --format '{{range .RepoTags}}{{.}}{{"\n"}}{{end}}' "$id")
  done < <(docker images --no-trunc \
             --filter "reference=${ACR_REGISTRY}/wukongquant/*:sha-*" \
             --format '{{.ID}} {{.CreatedAt}}')

  if [ "${#doomed[@]}" -eq 0 ]; then
    log "  nothing to prune (keep last ${IMAGE_KEEP_LAST_N}/repo, ${IMAGE_KEEP_HOURS}h, min age ${IMAGE_MIN_AGE_HOURS}h)"
    return 0
  fi
  log "  ${#doomed[@]} superseded release image(s) (keep last ${IMAGE_KEEP_LAST_N}/repo, ${IMAGE_KEEP_HOURS}h, min age ${IMAGE_MIN_AGE_HOURS}h)"
  if [ "$dry_run" = "--dry-run" ]; then
    printf '    %s\n' "${targets[@]}"
    return 0
  fi
  # Report the delta, not just the intent. The bug this replaced was a prune
  # that printed a success line every run while reclaiming exactly nothing, so
  # the log needs a number that can read 0 and be noticed.
  local before after survived=0 id
  before="$(docker images -q | wc -l)"
  timeout 120 docker rmi "${targets[@]}" >/dev/null 2>&1 || true
  after="$(docker images -q | wc -l)"
  log "  images: ${before} -> ${after}"

  # ...and a number nobody reads is not a closed loop, so give it a verdict.
  # "Matched N images, removed none" is exactly the 2026-10-16 shape: rmi
  # refuses an image referenced by several repositories, the run logged success
  # anyway, and the host filled up over the following days. Counted by
  # re-inspecting the ids we aimed at rather than by the delta above, because
  # `docker images -q` counts rows and a tag-only removal can leave it flat.
  for id in "${doomed[@]}"; do
    if docker image inspect "$id" >/dev/null 2>&1; then
      survived=$((survived + 1))
    fi
  done
  if [ "$survived" -gt 0 ]; then
    warn "release prune freed nothing on $(hostname)" \
      "${survived} of ${#doomed[@]} superseded release image(s) survived docker rmi (images ${before} -> ${after}); the prune is a silent no-op again -- check the tags it aimed at"
  fi
}

# The other half of the same lesson: a prune that ran is not a disk that is fine.
# The threshold is on the stock, not on the flow -- a deploy that finds nothing
# to prune is the normal steady state and must stay quiet, while a host that is
# nearly full is a countdown regardless of how healthy the prune looks.
check_disk_pressure() {
  local used avail
  used="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
  [ -n "$used" ] || return 0
  if [ "$used" -ge "$DISK_ALERT_PCT" ]; then
    avail="$(df -h --output=avail / 2>/dev/null | tail -1 | tr -d ' ' || true)"
    warn "disk pressure on $(hostname)" \
      "/ is ${used}% used (${avail:-?} free) after pruning (keep last ${IMAGE_KEEP_LAST_N}/repo, ${IMAGE_KEEP_HOURS}h); deploys start dying at 100% -- run the Host maintenance workflow, which can reclaim what a deploy must not touch"
  fi
}

# A trader container that binds the wrong bqbox starts cleanly and looks alive:
# the QMT model is running and answering, just on the other mailbox. The client
# then polls an empty directory until ping times out and crash-loops. The sim
# container needs the E: drive client from docker-compose.local.yml; the live
# container needs the D: drive live client from the base file. Dropping the
# local overlay once cost a crash-loop on 2026-10-31 and again on 2026-11-06,
# so the check is mechanical now instead of relying on remembering the flag.
check_trader_mailboxes() {
  local svc container src expect target
  for svc in quant-trader quant-trader-live; do
    if [ "${#SERVICES[@]}" -gt 0 ]; then
      target=0
      for t in "${SERVICES[@]}"; do
        [ "$t" = "$svc" ] && target=1
      done
      [ "$target" -eq 1 ] || continue
    fi
    container="$svc"
    src="$(docker inspect "$container" \
      --format '{{range .Mounts}}{{if eq .Destination "/app/bqbox"}}{{.Source}}{{end}}{{end}}' \
      2>/dev/null || true)"
    if [ -z "$src" ]; then
      # On a full deploy the trader containers are legitimately absent
      # (profile-gated). Only an explicitly targeted service that failed to
      # come up deserves a warning.
      if [ "${#SERVICES[@]}" -gt 0 ]; then
        warn "trader mailbox" "$svc: targeted but no /app/bqbox mount found (container missing or not running); cannot verify which QMT client it talks to"
      fi
      continue
    fi
    case "$svc" in
      quant-trader)      expect="/mnt/e/国金QMT交易端模拟/" ;;
      quant-trader-live) expect="/mnt/d/国金证券QMT交易端/" ;;
    esac
    case "$src" in
      "$expect"*) : ;;
      *)
        warn "trader mailbox" "$svc: /app/bqbox -> $src (expected under $expect). The other QMT client will not answer this mailbox; expect 'file rpc timeout: ping' and a crash-loop. Did you drop -f docker-compose.local.yml?"
        ;;
    esac
  done
}

main() {
  SERVICES=("$@")
  require_files
  resolve_local_runtime_profiles
  if [ -f docker-compose.115.yml ] && _host_is_115; then
    log "COMPOSE_HOST_PROFILE=115: using docker-compose.115.yml memory limits"
  fi
  stop_local_services_for_external_runtimes

  local explicit_services=0
  if [ "${#SERVICES[@]}" -gt 0 ]; then
    explicit_services=1
  fi
  expand_mcp_services
  filter_mcp_services_on_115
  filter_services_on_115
  stop_mcp_on_115
  stop_services_not_allowed_on_115
  filter_services_for_external_runtimes
  if [ "$explicit_services" -eq 1 ] && [ "${#SERVICES[@]}" -eq 0 ]; then
    log "No services left to deploy after runtime/MCP/115-allowlist filters"
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

  check_trader_mailboxes

  # The old line here was `docker image prune -f`, which removes only *dangling*
  # images. Every release carries a sha-* tag, so a superseded one is never
  # dangling: that command deleted nothing, printed "Total reclaimed space: 0B"
  # and left the deploy green. That silent no-op is how this host's disk
  # reached 100% and stalled deploys at `git fetch` on 2026-10-16.
  log "Pruning superseded release images (keeping ${IMAGE_KEEP_HOURS}h)"
  prune_release_images
  check_disk_pressure

  log "Deploy finished"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
