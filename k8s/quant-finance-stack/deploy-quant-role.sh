#!/usr/bin/env bash
# Shared renderer/deployer for quant worker roles on Kubernetes.
#
# Usage:
#   deploy-quant-role.sh <role> [--render]
#
# Roles: scorer | researcher | factor-researcher | portfolio | data-engine |
#        backtest | analyzer
#
# K8S_REPLICAS overrides replica count where allowed (scorer/portfolio/data-engine/
# backtest/analyzer must stay at 1 unless noted).
set -euo pipefail

show_help() {
  cat <<'EOF'
Deploy a quant worker role to Kubernetes (namespace aipoc by default).

Usage:
  deploy-quant-role.sh <role> [option]
  deploy-quant-role.sh --help

Roles:
  scorer        Daily stock-scoring scheduler (singleton).
  researcher    Portfolio-research queue worker (scalable).
  factor-researcher
                Alpha158 factor backtest queue worker (scalable; one job
                holds several GB, so give each replica its own memory).
  portfolio     Plan generation + paper-trading cron (singleton).
  data-engine   Market data sync + cron (singleton).
  backtest      Backtest queue + screening (singleton).
  analyzer      Analysis task worker (default singleton).

Options:
  --render     Print resolved manifest without applying.
  -h, --help   Show this help.

Image tags come from apps/versions.env. Image repositories default from
QUANT_SCORER_IMAGE_REPOSITORY parent path (wukongquant/*) or per-role overrides:
  QUANT_DATA_ENGINE_IMAGE_REPOSITORY
  BACKTEST_WORKER_IMAGE_REPOSITORY
  QUANT_ANALYZER_IMAGE_REPOSITORY

Runtime gates (apps/env/common.env or apps/.env for dev):
  QUANT_SCORER_RUNTIME, PORTFOLIO_RESEARCH_RUNTIME, FACTOR_BACKTEST_RUNTIME,
  QUANT_PORTFOLIO_RUNTIME, QUANT_DATA_ENGINE_RUNTIME,
  BACKTEST_WORKER_RUNTIME, QUANT_ANALYZER_RUNTIME
  Each must be external_k8s before deploy (except --render).

K8S_NAMESPACE, K8S_REPLICAS, K8S_ROLLOUT_TIMEOUT, K8S_DEPLOY_ENV_FILE.
EOF
}

usage() {
  echo "Usage: $0 {scorer|researcher|factor-researcher|portfolio|data-engine|backtest|analyzer} [--render]" >&2
  echo "Run '$0 --help' for details." >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
case "$1" in
  -h | --help)
    show_help
    exit 0
    ;;
esac

ROLE="$1"
shift

case "${1:-}" in
  -h | --help)
    show_help
    exit 0
    ;;
esac

MODE="apply"
if [ "${1:-}" = "--render" ]; then
  MODE="render"
  shift
fi
[ "$#" -eq 0 ] || usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$INFRA_ROOT/apps/versions.env}"
DEPLOY_ENV_FILE="${K8S_DEPLOY_ENV_FILE:-$INFRA_ROOT/apps/.env}"
COMMON_ENV_FILE="${K8S_COMMON_ENV_FILE:-$INFRA_ROOT/apps/env/common.env}"
NAMESPACE="${K8S_NAMESPACE:-aipoc}"
ROLLOUT_TIMEOUT="${K8S_ROLLOUT_TIMEOUT:-10m}"

env_file_get() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

runtime_from_files() {
  local key="$1"
  local v
  v="$(env_file_get "$key" "$DEPLOY_ENV_FILE")"
  if [ -z "$v" ] && [ -f "$COMMON_ENV_FILE" ]; then
    v="$(env_file_get "$key" "$COMMON_ENV_FILE")"
  fi
  echo "${v:-local_docker}"
}

case "$ROLE" in
  scorer)
    DEPLOYMENT="quant-scorer"
    MANIFEST_NAME="quant-scorer.yaml"
    RUNTIME_KEY="QUANT_SCORER_RUNTIME"
    IMAGE_PLACEHOLDER="quant-scorer:latest"
    TAG_KEY="QUANT_SCORER_IMAGE_TAG"
  ;;
  researcher)
    DEPLOYMENT="quant-researcher"
    MANIFEST_NAME="quant-researcher.yaml"
    RUNTIME_KEY="PORTFOLIO_RESEARCH_RUNTIME"
    IMAGE_PLACEHOLDER="quant-scorer:latest"
    TAG_KEY="QUANT_SCORER_IMAGE_TAG"
  ;;
  factor-researcher)
    DEPLOYMENT="quant-factor-researcher"
    MANIFEST_NAME="quant-factor-researcher.yaml"
    RUNTIME_KEY="FACTOR_BACKTEST_RUNTIME"
    IMAGE_PLACEHOLDER="quant-scorer:latest"
    TAG_KEY="QUANT_SCORER_IMAGE_TAG"
  ;;
  portfolio)
    DEPLOYMENT="quant-portfolio"
    MANIFEST_NAME="quant-portfolio.yaml"
    RUNTIME_KEY="QUANT_PORTFOLIO_RUNTIME"
    IMAGE_PLACEHOLDER="quant-scorer:latest"
    TAG_KEY="QUANT_SCORER_IMAGE_TAG"
  ;;
  data-engine)
    DEPLOYMENT="quant-data-engine"
    MANIFEST_NAME="quant-data-engine.yaml"
    RUNTIME_KEY="QUANT_DATA_ENGINE_RUNTIME"
    IMAGE_PLACEHOLDER="quant-data-engine:latest"
    TAG_KEY="QUANT_DATA_ENGINE_IMAGE_TAG"
  ;;
  backtest)
    DEPLOYMENT="backtest-worker"
    MANIFEST_NAME="backtest-worker.yaml"
    RUNTIME_KEY="BACKTEST_WORKER_RUNTIME"
    IMAGE_PLACEHOLDER="backtest-worker:latest"
    TAG_KEY="BACKTEST_WORKER_IMAGE_TAG"
  ;;
  analyzer)
    DEPLOYMENT="quant-analyzer"
    MANIFEST_NAME="quant-analyzer.yaml"
    RUNTIME_KEY="QUANT_ANALYZER_RUNTIME"
    IMAGE_PLACEHOLDER="quant-analyzer:latest"
    TAG_KEY="QUANT_ANALYZER_IMAGE_TAG"
  ;;
  *)
    usage
    ;;
esac

MANIFEST="$SCRIPT_DIR/base-workers/$MANIFEST_NAME"

if [ ! -f "$VERSIONS_FILE" ]; then
  echo "ERROR: versions file not found: $VERSIONS_FILE" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 1
fi

image_tag="$(env_file_get "$TAG_KEY" "$VERSIONS_FILE")"
if [ -z "$image_tag" ]; then
  echo "ERROR: $TAG_KEY is missing from $VERSIONS_FILE" >&2
  exit 1
fi

scorer_repo="$(env_file_get QUANT_SCORER_IMAGE_REPOSITORY "$DEPLOY_ENV_FILE")"
if [ -z "$scorer_repo" ]; then
  scorer_repo="$(env_file_get QUANT_SCORER_IMAGE_REPOSITORY "$COMMON_ENV_FILE")"
fi
if [ -z "$scorer_repo" ]; then
  echo "ERROR: set QUANT_SCORER_IMAGE_REPOSITORY in $DEPLOY_ENV_FILE or env/common.env" >&2
  exit 1
fi

acr_parent="${scorer_repo%/*}"
image_repository="$scorer_repo"
case "$ROLE" in
  data-engine)
    image_repository="$(env_file_get QUANT_DATA_ENGINE_IMAGE_REPOSITORY "$DEPLOY_ENV_FILE")"
    image_repository="${image_repository:-$(env_file_get QUANT_DATA_ENGINE_IMAGE_REPOSITORY "$COMMON_ENV_FILE")}"
    image_repository="${image_repository:-${acr_parent}/quant-data-engine}"
    ;;
  backtest)
    image_repository="$(env_file_get BACKTEST_WORKER_IMAGE_REPOSITORY "$DEPLOY_ENV_FILE")"
    image_repository="${image_repository:-$(env_file_get BACKTEST_WORKER_IMAGE_REPOSITORY "$COMMON_ENV_FILE")}"
    image_repository="${image_repository:-${acr_parent}/backtest-worker}"
    ;;
  analyzer)
    image_repository="$(env_file_get QUANT_ANALYZER_IMAGE_REPOSITORY "$DEPLOY_ENV_FILE")"
    image_repository="${image_repository:-$(env_file_get QUANT_ANALYZER_IMAGE_REPOSITORY "$COMMON_ENV_FILE")}"
    image_repository="${image_repository:-${acr_parent}/quant-analyzer}"
    ;;
esac

if [[ ! "$image_repository" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
  echo "ERROR: invalid image repository: $image_repository" >&2
  exit 1
fi
if [[ ! "$image_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: invalid image tag: $image_tag" >&2
  exit 1
fi

replicas="${K8S_REPLICAS:-}"
if [ -n "$replicas" ] && [[ ! "$replicas" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: K8S_REPLICAS must be a positive integer: $replicas" >&2
  exit 1
fi

singleton_roles="scorer portfolio data-engine backtest analyzer"
if [[ " $singleton_roles " == *" $ROLE "* ]] && [ -n "$replicas" ] && [ "$replicas" != "1" ]; then
  echo "ERROR: $DEPLOYMENT must remain a singleton (K8S_REPLICAS=1)" >&2
  exit 1
fi

image="${image_repository}:${image_tag}"

render_manifest() {
  local out
  out="$(awk -v image="$image" -v placeholder="$IMAGE_PLACEHOLDER" -v replicas="$replicas" '
    $0 ~ ("image: " placeholder) {
      sub("image: " placeholder, "image: " image)
      image_replaced++
    }
    replicas != "" && /^  replicas: [0-9]+[[:space:]]*$/ {
      sub(/replicas: [0-9]+/, "replicas: " replicas)
      replicas_replaced++
    }
    { print }
    END {
      if (image_replaced != 1) {
        print "ERROR: expected exactly one image placeholder " placeholder > "/dev/stderr"
        exit 1
      }
      if (replicas != "" && replicas_replaced != 1) {
        print "ERROR: expected exactly one replicas field" > "/dev/stderr"
        exit 1
      }
    }
  ' "$MANIFEST")" || return 1

  printf '%s\n' "$out"
}

if [ "$MODE" = "render" ]; then
  render_manifest
  exit 0
fi

runtime_value="$(runtime_from_files "$RUNTIME_KEY")"
if [ "$runtime_value" != "external_k8s" ]; then
  echo "ERROR: $RUNTIME_KEY must be external_k8s before deploying $DEPLOYMENT (got ${runtime_value})" >&2
  exit 1
fi

if [ -z "$replicas" ]; then
  replicas="$(
    kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || true
  )"
fi
if [[ " $singleton_roles " == *" $ROLE "* ]] && [ -n "$replicas" ] && [ "$replicas" != "1" ]; then
  echo "ERROR: existing $DEPLOYMENT has $replicas replicas; reduce to 1 before deployment" >&2
  exit 1
fi

replica_message="${replicas:-manifest default}"
echo "Deploying $DEPLOYMENT image $image to namespace $NAMESPACE (replicas: $replica_message)"
render_manifest | kubectl -n "$NAMESPACE" apply -f -
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout="$ROLLOUT_TIMEOUT"
