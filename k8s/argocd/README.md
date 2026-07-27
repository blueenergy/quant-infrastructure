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

CI can enforce consistency:

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

## Coexistence with `deploy-quant-role.sh`

Both apply the same manifests. Prefer **one** control plane:

- **GitOps**: change Git → Argo sync; avoid manual `kubectl apply` for the same fields.
- **Manual**: `deploy-quant-role.sh` still works; disable Argo `selfHeal` if you need ad-hoc drift.

## Scope

This Application does **not** deploy quant-api, web, or Compose-only services—only the
worker Deployments already on NKS (scorer, researcher, portfolio, data-engine, backtest, analyzer).
