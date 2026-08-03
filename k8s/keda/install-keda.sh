#!/usr/bin/env bash
# Install KEDA on the target cluster.
#
# KEDA is installed but NOT currently driving any workload. See README.md in
# this directory for why, and read it before adding a ScaledObject.
#
# Prerequisites:
#   - kubectl context pointing at NKS (e.g. KUBECONFIG=~/.kube/config.admin.nks1005)
#   - helm 3 or later
#   - Cluster-admin rights (KEDA installs CRDs and ClusterRoles)
#
# Usage:
#   export KUBECONFIG=~/.kube/config.admin.nks1005
#   ./k8s/keda/install-keda.sh
#   ./k8s/keda/install-keda.sh --uninstall
set -euo pipefail

# KEDA 2.20 is tested against Kubernetes v1.33-v1.35; the cluster runs v1.33.
# Check https://keda.sh/docs/latest/operate/cluster/ before bumping this.
KEDA_VERSION="${KEDA_VERSION:-2.20.2}"
KEDA_NAMESPACE="${KEDA_NAMESPACE:-keda}"
ACTION="install"

for arg in "$@"; do
  case "$arg" in
    --uninstall) ACTION="uninstall" ;;
    -h | --help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [ "$ACTION" = "uninstall" ]; then
  echo "==> Uninstalling KEDA"
  helm uninstall keda --namespace "$KEDA_NAMESPACE" || true
  echo "NOTE: helm uninstall leaves the KEDA CRDs behind. Remove them only if"
  echo "      no ScaledObject or TriggerAuthentication is still defined:"
  echo "      kubectl get crd | grep keda.sh"
  exit 0
fi

echo "==> Installing KEDA ${KEDA_VERSION} into namespace ${KEDA_NAMESPACE}"
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo update kedacore >/dev/null

helm upgrade --install keda kedacore/keda \
  --namespace "$KEDA_NAMESPACE" \
  --create-namespace \
  --version "$KEDA_VERSION" \
  --wait --timeout 5m

echo "==> Verifying"
kubectl -n "$KEDA_NAMESPACE" get pods
kubectl get crd | grep keda.sh

echo ""
echo "KEDA is installed. Nothing uses it yet — see k8s/keda/README.md before"
echo "adding a ScaledObject, especially the note about Argo CD and replicas."
