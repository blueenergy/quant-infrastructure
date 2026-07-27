#!/usr/bin/env bash
# Install Argo CD on the target cluster and register the quant-aipoc-workers app.
#
# Prerequisites:
#   - kubectl context pointing at NKS (e.g. KUBECONFIG=~/.kube/config.admin.nks1005)
#   - Namespace aipoc exists with Secret quant-secrets (trigger URLs + Mongo + S3)
#   - Git access to github.com/blueenergy/quant-infrastructure (HTTPS or SSH)
#
# Usage:
#   export KUBECONFIG=~/.kube/config.admin.nks1005
#   ./k8s/argocd/install-argocd.sh
#   # Private repo: export ARGOCD_REPO_URL=git@github.com:blueenergy/quant-infrastructure.git
#   #              export ARGOCD_GIT_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519
#   ./k8s/argocd/install-argocd.sh --with-app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"
REPO_URL="${ARGOCD_REPO_URL:-https://github.com/blueenergy/quant-infrastructure.git}"
WITH_APP=0

for arg in "$@"; do
  case "$arg" in
    --with-app) WITH_APP=1 ;;
    -h | --help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> Installing Argo CD (${ARGOCD_VERSION})"
kubectl get namespace argocd >/dev/null 2>&1 || kubectl create namespace argocd
  kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" --server-side --force-conflicts 2>/dev/null \
    || kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "==> Waiting for argocd-server"
kubectl -n argocd rollout status deployment/argocd-server --timeout=10m

if [ -n "${ARGOCD_GIT_SSH_PRIVATE_KEY_FILE:-}" ] && [ -f "${ARGOCD_GIT_SSH_PRIVATE_KEY_FILE}" ]; then
  echo "==> Registering Git repository (SSH)"
  kubectl -n argocd create secret generic repo-quant-infrastructure \
    --from-literal=type=git \
    --from-literal=url="${REPO_URL}" \
    --from-file=sshPrivateKey="${ARGOCD_GIT_SSH_PRIVATE_KEY_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd label secret repo-quant-infrastructure argocd.argoproj.io/secret-type=repository --overwrite
elif [ -n "${ARGOCD_GITHUB_TOKEN:-}" ]; then
  echo "==> Registering Git repository (HTTPS token)"
  kubectl -n argocd create secret generic repo-quant-infrastructure \
    --from-literal=type=git \
    --from-literal=url="${REPO_URL}" \
    --from-literal=username=git \
    --from-literal=password="${ARGOCD_GITHUB_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n argocd label secret repo-quant-infrastructure argocd.argoproj.io/secret-type=repository --overwrite
else
  echo "NOTE: No ARGOCD_GIT_SSH_PRIVATE_KEY_FILE or ARGOCD_GITHUB_TOKEN set."
  echo "      Public HTTPS clone may work for public repos; otherwise add credentials and re-run."
fi

if [ "$WITH_APP" -eq 1 ]; then
  echo "==> Applying Application quant-aipoc-workers"
  kubectl apply -f "${SCRIPT_DIR}/applications/quant-aipoc-workers.yaml"
  kubectl -n argocd patch application quant-aipoc-workers --type merge -p \
    '{"spec":{"source":{"repoURL":"'"${REPO_URL}"'"}}}' 2>/dev/null || true
fi

echo ""
echo "Argo CD UI (port-forward):"
echo "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "  https://localhost:8080  user: admin"
echo "  password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
echo ""
echo "After git push, ensure overlay images match apps/versions.env:"
echo "  ${INFRA_ROOT}/k8s/quant-finance-stack/scripts/sync-overlay-images.sh"
