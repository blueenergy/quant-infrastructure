# Argo CD on NKS (GitOps for aipoc workers)

Argo CD watches [`overlays/aipoc-workers`](../quant-finance-stack/overlays/aipoc-workers)
in this repo and syncs the six `external_k8s` Deployments in namespace `aipoc`.

## Version bumps (link to `apps/versions.env`)

Image tags in the overlay are generated from `apps/versions.env`. After CI or a manual
tag bump, run and commit:

```bash
k8s/quant-finance-stack/scripts/sync-overlay-images.sh
git add k8s/quant-finance-stack/overlays/aipoc-workers/kustomization.yaml
```

Argo CD auto-syncs when that file changes on `main` (same commit as `versions.env` is ideal).

You normally do not have to: the `Deploy app stack` workflow regenerates the overlay
from `apps/versions.env` and commits it on every deploy, which is how an app CI tag
bump reaches Argo CD. Run the check locally to see drift before pushing:

```bash
k8s/quant-finance-stack/scripts/sync-overlay-images.sh --check
```

## Install

```bash
export KUBECONFIG=~/.kube/config.admin.nks1005

# Optional private repo credentials:
# export ARGOCD_REPO_URL=git@github.com:blueenergy/quant-infrastructure.git
# export ARGOCD_GIT_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519

chmod +x k8s/argocd/install-argocd.sh
k8s/argocd/install-argocd.sh --with-app
```

Prerequisites:

- `aipoc` namespace and `quant-secrets` (including `INTRADAY_T0_TRIGGER_*` for data-engine)
- Overlay committed and pushed to GitHub before the Application can sync

## UI

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open https://localhost:8080 (admin / initial secret from install script output).

## Ingress + HTTPS + access control (NKS nginx)

NKS1005 already runs **ingress-nginx** (`ingressClassName: nginx`) with VIPs
`10.183.48.255`, `10.183.49.106`, `10.183.50.117` (same as Grafana/Rancher).

### 1. DNS

Host (wildcard TLS `*.prod.wingrnc...` already on cluster):

**`argocd.prod.wingrnc.es-ea-os-chn-1005.k8s.dyn.nesc.nokia.net`**

→ ingress VIPs `10.183.48.255`, `10.183.49.106`, or `10.183.50.117` (same as Grafana/Rancher).

### 2. TLS certificate

Pick one:

- **Reuse** wildcard Secret `tls` from `monitoring` if it covers your host (see `tls-cert.example.yaml`).
- **cert-manager** `Certificate` with Issuer `rancher` in `cattle-system` (platform-dependent).
- **Bring your own** PEM into `Secret/argocd-server-tls` in namespace `argocd`.

### 3. Argo external URL

```bash
sed 's/ARGOCD_HOST/argocd.prod.wingrnc.es-ea-os-chn-1005.k8s.dyn.nesc.nokia.net/' \
  k8s/argocd/argocd-cm-url-patch.example.yaml | kubectl apply -f -
```

### 4. Ingress manifest

```bash
chmod +x k8s/argocd/apply-ingress.sh
k8s/argocd/apply-ingress.sh
```

Or manually: copy `monitoring/tls` to `argocd`, then `kubectl apply -f ingress-argocd.yaml` and `argocd-cm-url.yaml`.

No IP whitelist on this Ingress; rely on Argo login + RBAC.

### 5. Argo-side hardening

- Change `admin` password in UI.
- Configure [Argo CD RBAC](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/) (`argocd-rbac-cm`).
- Later: **Dex / OIDC** for corporate SSO (edit `argocd-cm` + `argocd-secret`).

### 6. Verify

```bash
curl -kI "https://argocd.prod.wingrnc.es-ea-os-chn-1005.k8s.dyn.nesc.nokia.net/"
```

From a disallowed IP you should see **403** (whitelist). From VPN/office, browser login page.

**Do not** expose Argo on `10.181.200.185` unless that host runs ingress—Argo lives on NKS, not the quant Docker host.

## Coexistence with `deploy-quant-role.sh`

Both apply the same manifests. Prefer **one** control plane:

- **GitOps**: change Git → Argo sync; avoid manual `kubectl apply` for the same fields.
- **Manual**: `deploy-quant-role.sh` still works; disable Argo `selfHeal` if you need ad-hoc drift.

## Scope

This Application does **not** deploy quant-api, web, or Compose-only services—only the
worker Deployments already on NKS (scorer, researcher, portfolio, data-engine, backtest, analyzer).
