#!/usr/bin/env bash
# Sync kustomize image tags in overlays/aipoc-workers from apps/versions.env.
#
# Usage:
#   sync-overlay-images.sh          # rewrite kustomization.yaml images
#   sync-overlay-images.sh --check  # exit 1 if out of date, without writing
#
# The deploy workflow runs the write mode and commits the result, so --check is
# for spotting drift locally before pushing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_ROOT="$(cd "$STACK_DIR/../.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$INFRA_ROOT/apps/versions.env}"
OVERLAY_DIR="$STACK_DIR/overlays/aipoc-workers"
KUSTOMIZATION="$OVERLAY_DIR/kustomization.yaml"
DEPLOY_ENV="${K8S_DEPLOY_ENV_FILE:-$INFRA_ROOT/apps/.env}"
COMMON_ENV="$INFRA_ROOT/apps/env/common.env"

MODE=write
if [ "${1:-}" = "--check" ]; then
  MODE=check
elif [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,8p' "$0"
  exit 0
elif [ -n "${1:-}" ]; then
  echo "Unknown option: $1" >&2
  exit 2
fi

env_file_get() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

scorer_repo="$(env_file_get QUANT_SCORER_IMAGE_REPOSITORY "$DEPLOY_ENV")"
scorer_repo="${scorer_repo:-$(env_file_get QUANT_SCORER_IMAGE_REPOSITORY "$COMMON_ENV")}"
scorer_repo="${scorer_repo:-$(env_file_get QUANT_SCORER_IMAGE_REPOSITORY "$INFRA_ROOT/apps/env/quant-scorer.env.example")}"
# .env.example is the only committed file carrying the key, so --check works on
# a bare CI checkout where apps/.env and env/common.env are absent.
scorer_repo="${scorer_repo:-$(env_file_get QUANT_SCORER_IMAGE_REPOSITORY "$INFRA_ROOT/apps/.env.example")}"
if [ -z "$scorer_repo" ]; then
  echo "ERROR: QUANT_SCORER_IMAGE_REPOSITORY not found" >&2
  exit 1
fi
acr_parent="${scorer_repo%/*}"

tag_get() {
  local key="$1"
  local v
  v="$(env_file_get "$key" "$VERSIONS_FILE")"
  if [ -z "$v" ]; then
    echo "ERROR: $key missing in $VERSIONS_FILE" >&2
    exit 1
  fi
  echo "$v"
}

SCORER_TAG="$(tag_get QUANT_SCORER_IMAGE_TAG)"
DATA_TAG="$(tag_get QUANT_DATA_ENGINE_IMAGE_TAG)"
BACKTEST_TAG="$(tag_get BACKTEST_WORKER_IMAGE_TAG)"
ANALYZER_TAG="$(tag_get QUANT_ANALYZER_IMAGE_TAG)"
RESEARCHER_REPLICAS="${K8S_RESEARCHER_REPLICAS:-2}"

tmp="$(mktemp)"
cat >"$tmp" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# GitOps overlay for NKS aipoc worker Deployments (Argo CD).
# Image tags are generated from apps/versions.env — run:
#   k8s/quant-finance-stack/scripts/sync-overlay-images.sh
namespace: aipoc

resources:
  - ../../base-workers

patches:
  - path: researcher-replicas-patch.yaml
  # Keep the cache producer revision identical to the immutable image tag.
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: quant-researcher
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: quant-researcher
      spec:
        template:
          spec:
            containers:
              - name: researcher
                env:
                  - name: PORTFOLIO_RESEARCH_CACHE_V2_PRODUCER_REVISION
                    value: ${SCORER_TAG}

labels:
  - pairs:
      app.kubernetes.io/part-of: quant-finance
      app.kubernetes.io/managed-by: argocd
    includeSelectors: false

images:
  - name: quant-scorer:latest
    newName: ${scorer_repo}
    newTag: ${SCORER_TAG}
  - name: quant-data-engine:latest
    newName: ${acr_parent}/quant-data-engine
    newTag: ${DATA_TAG}
  - name: backtest-worker:latest
    newName: ${acr_parent}/backtest-worker
    newTag: ${BACKTEST_TAG}
  - name: quant-analyzer:latest
    newName: ${acr_parent}/quant-analyzer
    newTag: ${ANALYZER_TAG}
EOF

if [ "$MODE" = check ]; then
  if ! cmp -s "$tmp" "$KUSTOMIZATION"; then
    echo "ERROR: $KUSTOMIZATION is out of sync with $VERSIONS_FILE" >&2
    echo "Run: k8s/quant-finance-stack/scripts/sync-overlay-images.sh" >&2
    diff -u "$KUSTOMIZATION" "$tmp" || true
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"
  echo "OK: overlay images match $VERSIONS_FILE"
  exit 0
fi

mkdir -p "$OVERLAY_DIR"
mv "$tmp" "$KUSTOMIZATION"

# Keep patch in sync for researcher replica count
cat >"$OVERLAY_DIR/researcher-replicas-patch.yaml" <<PATCHEOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: quant-researcher
spec:
  replicas: ${RESEARCHER_REPLICAS}
PATCHEOF

echo "Wrote $KUSTOMIZATION (scorer/data/backtest/analyzer tags from versions.env)"
