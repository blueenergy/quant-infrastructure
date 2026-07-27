#!/usr/bin/env bash
# Expose Argo CD at argocd.prod.wingrnc.es-ea-os-chn-1005.k8s.dyn.nesc.nokia.net
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config.admin.nks1005}"

echo "==> Copy wildcard TLS secret tls from monitoring -> argocd"
kubectl -n monitoring get secret tls -o yaml \
  | sed 's/namespace: monitoring/namespace: argocd/' \
  | kubectl apply -f -

echo "==> Argo server insecure HTTP behind ingress TLS"
kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd rollout restart deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-server --timeout=3m

echo "==> Apply Ingress + argocd-cm url"
kubectl apply -f "${SCRIPT_DIR}/ingress-argocd.yaml"
kubectl apply -f "${SCRIPT_DIR}/argocd-cm-url.yaml"

echo "==> Ingress status"
kubectl -n argocd get ingress argocd-server

echo ""
echo "Open: https://argocd.prod.wingrnc.es-ea-os-chn-1005.k8s.dyn.nesc.nokia.net/"
echo "Ensure DNS for that host points to an ingress VIP (10.183.48.255 etc.)."
