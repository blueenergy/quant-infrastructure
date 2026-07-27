#!/usr/bin/env bash
# Shared renderer/deployer for stock-scoring-system Kubernetes roles.
#
# Usage:
#   deploy-quant-role.sh scorer [--render]
#   deploy-quant-role.sh researcher [--render]
#
# K8S_REPLICAS overrides the manifest replica count. Without an override,
# deployment preserves an existing Deployment's replica count and uses the
# manifest default only on first creation.
set -euo pipefail

show_help() {
  cat <<'EOF'
Deploy a stock-scoring-system role to Kubernetes.

Usage:
  deploy-quant-role.sh <role> [option]
  deploy-quant-role.sh --help

Roles:
  scorer       Weekday 19:00 stock-scoring scheduler. Must remain at 1 replica.
  researcher   Portfolio-research queue worker. Supports multiple replicas.

Options:
  --render     Print the resolved Kubernetes manifest without applying it.
  -h, --help   Show this help and exit.

Image configuration:
  QUANT_SCORER_IMAGE_REPOSITORY
      Image repository from the shell or apps/.env.
  QUANT_SCORER_IMAGE_TAG
      Immutable image tag read from apps/versions.env.

Deployment configuration:
  K8S_NAMESPACE          Target namespace (default: aipoc).
  K8S_REPLICAS           Explicit replica count. Scorer only accepts 1.
  K8S_ROLLOUT_TIMEOUT    Rollout wait timeout (default: 10m).
  K8S_DEPLOY_ENV_FILE    Runtime env file (default: apps/.env).
  VERSIONS_FILE          Image versions file (default: apps/versions.env).

New cluster prerequisites:
  1. Select a kubectl context and create the namespace:

       kubectl config current-context
       kubectl create namespace aipoc

     Use K8S_NAMESPACE=<name> when the namespace is not aipoc.

  2. Create quant-secrets from the provided template:

       cp templates/secret.env.example templates/secret.env
       # Edit templates/secret.env; never commit the populated file.
       kubectl -n aipoc create secret generic quant-secrets \
         --from-env-file=templates/secret.env \
         --dry-run=client -o yaml | kubectl apply -f -

     Both roles require MONGO_URI and MONGO_DB. Scorer also needs
     TUSHARE_TOKEN. Researcher with external_k8s requires the complete
     PORTFOLIO_RESEARCH_S3_* configuration and an existing aipoc bucket.

  3. Verify Pod network access:
     - MongoDB host and port in MONGO_URI must be reachable from worker nodes.
     - Researcher must reach the configured eecloud S3 endpoint.
     - Nodes must resolve and pull from the configured ACR repository.
       The current ACR repository permits anonymous pulls, so no pull secret
       is required.

  4. Prevent duplicate schedulers/workers on the Compose host:
     - Set QUANT_SCORER_RUNTIME=external_k8s before deploying scorer.
     - Set PORTFOLIO_RESEARCH_RUNTIME=external_k8s before deploying researcher.
     - Stop/remove the corresponding local Compose service.

  5. Check the manifest before the first deployment:

       ./deploy-quant-role.sh scorer --render
       ./deploy-quant-role.sh researcher --render
       kubectl auth can-i create deployments -n aipoc

Runtime safety:
  scorer requires QUANT_SCORER_RUNTIME=external_k8s.
  researcher requires PORTFOLIO_RESEARCH_RUNTIME=external_k8s.
  Without K8S_REPLICAS, an existing Deployment keeps its current replica count;
  a new Deployment uses the replica count in its manifest.

Examples:
  ./deploy-quant-role.sh scorer --render
  ./deploy-quant-role.sh scorer
  K8S_REPLICAS=3 ./deploy-quant-role.sh researcher
  K8S_NAMESPACE=aipoc K8S_ROLLOUT_TIMEOUT=15m \
    ./deploy-quant-role.sh researcher
EOF
}

usage() {
  echo "Usage: $0 {scorer|researcher} [--render]" >&2
  echo "Run '$0 --help' for detailed guidance." >&2
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

case "$ROLE" in
  scorer)
    DEPLOYMENT="quant-scorer"
    MANIFEST_NAME="quant-scorer.yaml"
    RUNTIME_KEY="QUANT_SCORER_RUNTIME"
    runtime_value="${QUANT_SCORER_RUNTIME:-}"
    ;;
  researcher)
    DEPLOYMENT="quant-researcher"
    MANIFEST_NAME="quant-researcher.yaml"
    RUNTIME_KEY="PORTFOLIO_RESEARCH_RUNTIME"
    runtime_value="${PORTFOLIO_RESEARCH_RUNTIME:-}"
    ;;
  *)
    usage
    ;;
esac

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
MANIFEST="$SCRIPT_DIR/base/$MANIFEST_NAME"
NAMESPACE="${K8S_NAMESPACE:-aipoc}"
ROLLOUT_TIMEOUT="${K8S_ROLLOUT_TIMEOUT:-10m}"

env_file_get() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

if [ ! -f "$VERSIONS_FILE" ]; then
  echo "ERROR: versions file not found: $VERSIONS_FILE" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 1
fi

image_tag="$(env_file_get QUANT_SCORER_IMAGE_TAG "$VERSIONS_FILE")"
image_repository="${QUANT_SCORER_IMAGE_REPOSITORY:-}"
if [ -z "$image_repository" ]; then
  image_repository="$(env_file_get QUANT_SCORER_IMAGE_REPOSITORY "$DEPLOY_ENV_FILE")"
fi
if [ -z "$runtime_value" ]; then
  runtime_value="$(env_file_get "$RUNTIME_KEY" "$DEPLOY_ENV_FILE")"
fi
runtime_value="${runtime_value:-local_docker}"

if [ -z "$image_repository" ]; then
  echo "ERROR: set QUANT_SCORER_IMAGE_REPOSITORY in the environment or $DEPLOY_ENV_FILE" >&2
  exit 1
fi
if [ -z "$image_tag" ]; then
  echo "ERROR: QUANT_SCORER_IMAGE_TAG is missing from $VERSIONS_FILE" >&2
  exit 1
fi
if [[ ! "$image_repository" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
  echo "ERROR: invalid QUANT_SCORER_IMAGE_REPOSITORY: $image_repository" >&2
  exit 1
fi
if [[ ! "$image_tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: invalid QUANT_SCORER_IMAGE_TAG: $image_tag" >&2
  exit 1
fi

replicas="${K8S_REPLICAS:-}"
if [ -n "$replicas" ] && [[ ! "$replicas" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: K8S_REPLICAS must be a positive integer: $replicas" >&2
  exit 1
fi
if [ "$ROLE" = "scorer" ] && [ -n "$replicas" ] && [ "$replicas" != "1" ]; then
  echo "ERROR: quant-scorer must remain a singleton (K8S_REPLICAS=1)" >&2
  exit 1
fi

image="${image_repository}:${image_tag}"
render_manifest() {
  awk -v image="$image" -v replicas="$replicas" '
    /^[[:space:]]+image: quant-scorer:latest[[:space:]]*$/ {
      sub(/image: quant-scorer:latest/, "image: " image)
      image_replaced++
    }
    replicas != "" && /^  replicas: [0-9]+[[:space:]]*$/ {
      sub(/replicas: [0-9]+/, "replicas: " replicas)
      replicas_replaced++
    }
    { print }
    END {
      if (image_replaced != 1) {
        print "ERROR: expected exactly one quant-scorer image placeholder" > "/dev/stderr"
        exit 1
      }
      if (replicas != "" && replicas_replaced != 1) {
        print "ERROR: expected exactly one replicas field" > "/dev/stderr"
        exit 1
      }
    }
  ' "$MANIFEST"
}

if [ "$MODE" = "render" ]; then
  render_manifest
  exit 0
fi

if [ "$runtime_value" != "external_k8s" ]; then
  echo "ERROR: $RUNTIME_KEY must be external_k8s before deploying $DEPLOYMENT" >&2
  exit 1
fi

if [ -z "$replicas" ]; then
  replicas="$(
    kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || true
  )"
fi
if [ "$ROLE" = "scorer" ] && [ -n "$replicas" ] && [ "$replicas" != "1" ]; then
  echo "ERROR: existing quant-scorer has $replicas replicas; reduce it to 1 before deployment" >&2
  exit 1
fi

replica_message="${replicas:-manifest default}"
echo "Deploying $DEPLOYMENT image $image to namespace $NAMESPACE (replicas: $replica_message)"
render_manifest | kubectl -n "$NAMESPACE" apply -f -
kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout="$ROLLOUT_TIMEOUT"
