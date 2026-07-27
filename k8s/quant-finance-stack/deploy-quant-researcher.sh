#!/usr/bin/env bash
# Render and deploy the standalone quant-researcher Deployment.
# - image repository: QUANT_SCORER_IMAGE_REPOSITORY (shell or apps/.env)
# - image tag:        QUANT_SCORER_IMAGE_TAG from apps/versions.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$INFRA_ROOT/apps/versions.env}"
DEPLOY_ENV_FILE="${K8S_DEPLOY_ENV_FILE:-$INFRA_ROOT/apps/.env}"
MANIFEST="$SCRIPT_DIR/base/quant-researcher.yaml"
NAMESPACE="${K8S_NAMESPACE:-aipoc}"

env_file_get() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

if [ ! -f "$VERSIONS_FILE" ]; then
  echo "ERROR: versions file not found: $VERSIONS_FILE" >&2
  exit 1
fi

image_tag="$(env_file_get QUANT_SCORER_IMAGE_TAG "$VERSIONS_FILE")"
image_repository="${QUANT_SCORER_IMAGE_REPOSITORY:-}"
if [ -z "$image_repository" ]; then
  image_repository="$(env_file_get QUANT_SCORER_IMAGE_REPOSITORY "$DEPLOY_ENV_FILE")"
fi

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

image="${image_repository}:${image_tag}"
render_manifest() {
  awk -v image="$image" '
    /image: quant-scorer:latest/ {
      sub(/image: quant-scorer:latest/, "image: " image)
      replaced++
    }
    { print }
    END {
      if (replaced != 1) {
        print "ERROR: expected exactly one quant-scorer image placeholder" > "/dev/stderr"
        exit 1
      }
    }
  ' "$MANIFEST"
}

if [ "${1:-}" = "--render" ]; then
  render_manifest
  exit 0
fi

echo "Deploying quant-researcher image $image to namespace $NAMESPACE"
render_manifest | kubectl -n "$NAMESPACE" apply -f -
