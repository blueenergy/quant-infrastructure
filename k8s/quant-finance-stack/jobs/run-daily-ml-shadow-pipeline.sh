#!/usr/bin/env bash
# Apply or run the daily ML pipeline: canonical materialize (hs300, a500) + shadow --once.
#
# Usage:
#   ./run-daily-ml-shadow-pipeline.sh --apply-cron
#   ./run-daily-ml-shadow-pipeline.sh --run-once
#   ./run-daily-ml-shadow-pipeline.sh --dry-run --apply-cron
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_ROOT="$(cd "$STACK_DIR/../.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$INFRA_ROOT/apps/versions.env}"
NAMESPACE="${K8S_NAMESPACE:-aipoc}"
DEFAULT_REPO="crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com/wukongquant/quant-model-trainer"

APPLY_CRON=0
DRY_RUN=0
RUN_ONCE=0
IMAGE_OVERRIDE="${IMAGE:-}"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage ;;
    --namespace) NAMESPACE="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --apply-cron) APPLY_CRON=1; shift ;;
    --run-once) RUN_ONCE=1; shift ;;
    --image) IMAGE_OVERRIDE="${2:?}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

if [ -n "$IMAGE_OVERRIDE" ]; then
  IMAGE="$IMAGE_OVERRIDE"
else
  TAG="$(awk -F= '$1=="QUANT_MODEL_TRAINER_IMAGE_TAG"{sub(/^[^=]*=/,""); gsub(/"/,""); print; exit}' "$VERSIONS_FILE")"
  REPO="${QUANT_MODEL_TRAINER_IMAGE_REPOSITORY:-$DEFAULT_REPO}"
  if [ -z "$TAG" ]; then
    echo "Missing QUANT_MODEL_TRAINER_IMAGE_TAG in $VERSIONS_FILE" >&2
    exit 1
  fi
  IMAGE="${REPO}:${TAG}"
fi

CRON_SRC="$STACK_DIR/base-workers/quant-ml-daily-shadow-pipeline-cronjob.yaml"
SHADOW_CRON_SRC="$STACK_DIR/base-workers/quant-model-shadow-cronjob.yaml"
MANIFEST="$(mktemp)"
sed -e "s|image: quant-model-trainer:latest|image: ${IMAGE}|" "$CRON_SRC" > "$MANIFEST"

if [ "$APPLY_CRON" -eq 1 ]; then
  echo "Applying pipeline CronJob + legacy shadow CronJob (suspended) image=${IMAGE} ns=${NAMESPACE}"
  if [ "$DRY_RUN" -eq 1 ]; then
    cat "$MANIFEST"
    rm -f "$MANIFEST"
    exit 0
  fi
  sed -e "s|image: quant-model-trainer:latest|image: ${IMAGE}|" "$SHADOW_CRON_SRC" | kubectl -n "$NAMESPACE" apply -f -
  kubectl -n "$NAMESPACE" apply -f "$MANIFEST"
  rm -f "$MANIFEST"
  echo "Ensure quant-model-shadow-profiles secret is set."
  exit 0
fi

if [ "$RUN_ONCE" -eq 1 ]; then
  JOB_NAME="quant-ml-daily-shadow-pipeline-manual-$(date +%s)"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "kubectl -n ${NAMESPACE} create job ${JOB_NAME} --from=cronjob/quant-ml-daily-shadow-pipeline"
    rm -f "$MANIFEST"
    exit 0
  fi
  kubectl -n "$NAMESPACE" apply -f "$MANIFEST"
  kubectl -n "$NAMESPACE" create job "$JOB_NAME" --from="cronjob/quant-ml-daily-shadow-pipeline"
  rm -f "$MANIFEST"
  kubectl -n "$NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout=3h
  kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}"
  exit 0
fi

echo "Specify --apply-cron or --run-once" >&2
rm -f "$MANIFEST"
exit 2
