#!/usr/bin/env bash
# Apply quant-model-shadow CronJob with ACR trainer image tag (same as materialize).
#
# Set MODEL_SHADOW_PROFILES on the cluster before daily runs, e.g.:
#   kubectl -n aipoc create secret generic quant-model-shadow-profiles \
#     --from-literal=MODEL_SHADOW_PROFILES='[{"source_job_id":"..."},{"source_job_id":"..."}]' \
#     --dry-run=client -o yaml | kubectl apply -f -
#
# Usage:
#   ./run-quant-model-shadow.sh --dry-run
#   ./run-quant-model-shadow.sh --apply-cron
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_ROOT="$(cd "$STACK_DIR/../.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-$INFRA_ROOT/apps/versions.env}"
NAMESPACE="${K8S_NAMESPACE:-aipoc}"
DEFAULT_REPO="crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com/wukongquant/quant-model-trainer"

APPLY_CRON=0
DRY_RUN=0
IMAGE_OVERRIDE="${IMAGE:-}"
RUN_ONCE=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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

CRON_SRC="$STACK_DIR/base-workers/quant-model-shadow-cronjob.yaml"
MANIFEST="$(mktemp)"
sed -e "s|image: quant-model-trainer:latest|image: ${IMAGE}|" "$CRON_SRC" > "$MANIFEST"

if [ "$APPLY_CRON" -eq 1 ]; then
  echo "Applying CronJob quant-model-shadow image=${IMAGE} ns=${NAMESPACE}"
  if [ "$DRY_RUN" -eq 1 ]; then
    cat "$MANIFEST"
    rm -f "$MANIFEST"
    exit 0
  fi
  kubectl -n "$NAMESPACE" apply -f "$MANIFEST"
  rm -f "$MANIFEST"
  echo "Ensure MODEL_SHADOW_PROFILES is set (secret quant-model-shadow-profiles or patch CronJob env)."
  exit 0
fi

if [ "$RUN_ONCE" -eq 1 ]; then
  JOB_NAME="quant-model-shadow-manual-$(date +%s)"
  cat >"$MANIFEST" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
      containers:
        - name: shadow
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - python
            - -m
            - quant_model_platform.workers.shadow_loop
            - --once
          envFrom:
            - secretRef:
                name: quant-secrets
          env:
            - name: TZ
              value: Asia/Shanghai
            - name: HOME
              value: /tmp
            - name: QUANT_ML_DB
              value: quant_ml
            - name: QUANT_ML_PARQUET_ROOT
              value: /tmp/quant_ml/parquet
            - name: QUANT_ML_PARQUET_BACKEND
              value: s3
            - name: QUANT_ML_S3_PREFIX
              value: quant_ml
            - name: QUANT_ML_S3_ENDPOINT
              valueFrom:
                secretKeyRef:
                  name: quant-secrets
                  key: PORTFOLIO_RESEARCH_S3_ENDPOINT
            - name: QUANT_ML_S3_BUCKET
              valueFrom:
                secretKeyRef:
                  name: quant-secrets
                  key: PORTFOLIO_RESEARCH_S3_BUCKET
            - name: QUANT_ML_S3_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: quant-secrets
                  key: PORTFOLIO_RESEARCH_S3_ACCESS_KEY
            - name: QUANT_ML_S3_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: quant-secrets
                  key: PORTFOLIO_RESEARCH_S3_SECRET_KEY
            - name: QUANT_ML_S3_REGION
              valueFrom:
                secretKeyRef:
                  name: quant-secrets
                  key: PORTFOLIO_RESEARCH_S3_REGION
            - name: MODEL_SHADOW_PROFILES
              valueFrom:
                secretKeyRef:
                  name: quant-model-shadow-profiles
                  key: MODEL_SHADOW_PROFILES
                  optional: true
          resources:
            requests:
              cpu: "1"
              memory: "4Gi"
            limits:
              cpu: "2"
              memory: "8Gi"
EOF
  if [ "$DRY_RUN" -eq 1 ]; then
    cat "$MANIFEST"
    rm -f "$MANIFEST"
    exit 0
  fi
  kubectl -n "$NAMESPACE" apply -f "$MANIFEST"
  rm -f "$MANIFEST"
  kubectl -n "$NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout=2h
  kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}"
  exit 0
fi

echo "Specify --apply-cron or --run-once (see --help)" >&2
rm -f "$MANIFEST"
exit 2
