#!/usr/bin/env bash
# Apply quant-ml-materialize-snapshot Job with the same ACR image tag as aipoc trainer.
#
# Usage:
#   ./run-quant-ml-materialize-snapshot.sh
#   ./run-quant-ml-materialize-snapshot.sh --index-code hs300 --wait
#   K8S_NAMESPACE=aipoc ./run-quant-ml-materialize-snapshot.sh --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_ROOT="$(cd "$STACK_DIR/../.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$INFRA_ROOT/apps/versions.env}"
NAMESPACE="${K8S_NAMESPACE:-aipoc}"
JOB_NAME="${QUANT_ML_MATERIALIZE_JOB_NAME:-quant-ml-materialize-snapshot}"
DEFAULT_REPO="crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com/wukongquant/quant-model-trainer"

INDEX_CODE="${INDEX_CODE:-hs300}"
START_DATE="${START_DATE:-20230101}"
END_DATE="${END_DATE:-20251231}"
WAIT=0
DRY_RUN=0
IMAGE_OVERRIDE="${IMAGE:-}"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage ;;
    --namespace) NAMESPACE="${2:?}"; shift 2 ;;
    --job-name) JOB_NAME="${2:?}"; shift 2 ;;
    --index-code) INDEX_CODE="${2:?}"; shift 2 ;;
    --start-date) START_DATE="${2:?}"; shift 2 ;;
    --end-date) END_DATE="${2:?}"; shift 2 ;;
    --wait) WAIT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
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

MANIFEST="$(mktemp)"
sed \
  -e "s|name: quant-ml-materialize-snapshot|name: ${JOB_NAME}|" \
  -e "s|image: quant-model-trainer:latest|image: ${IMAGE}|" \
  -e "s|- hs300|- ${INDEX_CODE}|" \
  -e "s|- \"20230101\"|- \"${START_DATE}\"|" \
  -e "s|- \"20251231\"|- \"${END_DATE}\"|" \
  "$SCRIPT_DIR/quant-ml-materialize-snapshot.yaml" > "$MANIFEST"

echo "Applying Job ${JOB_NAME} image=${IMAGE} index=${INDEX_CODE} ${START_DATE}-${END_DATE} ns=${NAMESPACE}"
if [ "$DRY_RUN" -eq 1 ]; then
  cat "$MANIFEST"
  rm -f "$MANIFEST"
  exit 0
fi

kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found=true
kubectl -n "$NAMESPACE" apply -f "$MANIFEST"
rm -f "$MANIFEST"

if [ "$WAIT" -eq 1 ]; then
  kubectl -n "$NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout=6h
  kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}"
fi

cat <<EOF

Follow logs:
  kubectl -n ${NAMESPACE} logs job/${JOB_NAME} -f

If ImagePullBackOff: image must match running trainer (see apps/versions.env QUANT_MODEL_TRAINER_IMAGE_TAG).

EOF
