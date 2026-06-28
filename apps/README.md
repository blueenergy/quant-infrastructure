# Application stack deployment (GitOps-lite, Push-style CD)

**Goal:** `quant-infrastructure` becomes the single source of truth for what
runs in production. App repos do **continuous delivery** (build + push image);
**deployment** is centralized here.

> **Migration status:** the `apps/` stack is NOT live in production yet. Until a
> service is migrated, the **authoritative** deployment is still its own repo's
> GitHub CI deploy job (the real `docker run` on the host). When reconciling a
> service into `docker-compose.yml`, **mirror that CI deploy faithfully**
> (same network mode, ports, volumes, env) — do not "improve" it during the
> move. Optimizations (e.g. unifying everything onto `quant-network`) come as a
> separate, deliberate step afterwards.

## Flow

```
app repo CI:  test -> build -> push image (sha tag)
                                   |
                                   v
              bump apps/versions.env (commit)  +  repository_dispatch(deploy)
                                   |
quant-infrastructure (source of truth):
   apps/docker-compose.yml   topology (all services use ${*_IMAGE_TAG})
   apps/versions.env         desired image tags  <-- CI edits this
   apps/.env                 runtime secrets (NOT committed)
                                   |
   .github/workflows/deploy.yml (this repo):
       repository_dispatch / workflow_dispatch
                                   |  SSH
                                   v
   production host: git pull  ->  apps/deploy.sh <services>
                                   ->  docker compose pull + up -d --wait
```

Key properties:
- **Reproducible / rollback**: every release is a commit to `versions.env`.
  Rollback = revert that line and re-trigger (or `workflow_dispatch`).
- **Smaller secret blast radius**: only this repo needs `VOLC_SSH_KEY` +
  production access. App repos only need registry push creds + `INFRA_REPO_TOKEN`
  (scoped to bump `versions.env` and send a dispatch).
- **No `:latest` in prod**: image tags are immutable `sha-xxxxxxx`.

## Files

| File | Committed | Purpose |
|---|---|---|
| `docker-compose.yml` | yes | Topology. All images use `${*_IMAGE_TAG:-latest}`. |
| `versions.env` | yes | Desired image tags (the "values.yaml"). CI edits this. |
| `env/common.env` | **no** (gitignored) | Runtime config shared by all services. |
| `env/<svc>.env` | **no** (gitignored) | Per-service runtime config & secrets. |
| `env/*.env.example` | yes | Templates for the above (copied on the host). |
| `.env` | **no** (gitignored) | Legacy single env, still used by not-yet-migrated services. |
| `deploy.sh` | yes | CD entrypoint, runs on the prod host. |
| `hooks/<svc>-{pre,post}.sh` | yes (optional) | Per-service deploy hooks (e.g. quant-api DB index migrations). |

## Env model: layered per-service files

Instead of one giant `.env`, each migrated service loads a **layered** set of
env files (later overrides earlier):

```yaml
    env_file:
      - env/common.env        # shared: MONGO_URI / MONGO_DB / REALTIME_DB_NAME / TZ
      - env/quant-data-engine.env   # service-specific vars & secrets
    # compose `environment:` (if any) overrides both — for toggles like
    # ENABLE_MCP_SERVER.
```

Benefits: small focused files; **least privilege** (a container only gets its
own secrets + common, not other services' secrets); no key collisions across
services; shared config stays DRY in `common.env`.

On the production host, copy the templates and fill real values:

```bash
cp env/common.env.example env/common.env
cp env/quant-data-engine.env.example env/quant-data-engine.env
```

Legacy `apps/.env` stays only until the last service migrates.

## Manual operations (on the production host)

```bash
cd ~/trading/quant-infrastructure
git pull
ALIYUN_USER=... ALIYUN_TOKEN=... ./apps/deploy.sh quant-data-engine   # one service
ALIYUN_USER=... ALIYUN_TOKEN=... ./apps/deploy.sh                     # whole stack
```

## Required GitHub config

In **quant-infrastructure** (secrets): `VOLC_SSH_KEY`, `VOLC_HOST`, `VOLC_USER`,
`ALIYUN_USER`, `ALIYUN_TOKEN`. Optional repo variable `INFRA_REMOTE_DIR`
(default `~/trading/quant-infrastructure`).

In **each app repo** (secret): `INFRA_REPO_TOKEN` — a PAT / fine-grained token
with `contents:write` on `blueenergy/quant-infrastructure` (used to bump
`versions.env` and POST `repository_dispatch`).

## Rollout status & per-repo migration checklist

Pilot: **quant-data-engine** (done in CI; verify before migrating the rest).

| Service | Image tag var | Migrated to central CD |
|---|---|---|
| quant-data-engine | `QUANT_DATA_ENGINE_IMAGE_TAG` | ✅ pilot |
| quant-api / mcp / scheduler | `QUANT_API_IMAGE_TAG` | ⬜ (needs index-migration hooks, MCP toggle, volumes) |
| quant-web | `QUANT_DASHBOARD_IMAGE_TAG` | ✅ |
| quant-scorer | `QUANT_SCORER_IMAGE_TAG` | ✅ |
| backtest-worker | `BACKTEST_WORKER_IMAGE_TAG` | ✅ |
| quant-analyzer | `QUANT_ANALYZER_IMAGE_TAG` | ✅ |
| quant-strategy-manager | `QUANT_STRATEGY_MANAGER_IMAGE_TAG` | ✅ |

To migrate a repo:
1. Make its service in `docker-compose.yml` **faithful** to the current CI
   deploy `docker run` (network mode, ports, volumes, `extra_hosts`, env,
   healthcheck, command) — preserve behavior, don't change the network model
   during the move. Add `env_file: [env/common.env, env/<svc>.env]` and create
   `env/<svc>.env.example` for its service-specific vars (the remote DB
   `MONGO_URI` is shared in `common.env`).
2. If the old deploy ran one-shot steps (e.g. quant-api index migrations),
   move them into `apps/hooks/<svc>-pre.sh` (or `-post.sh`).
3. In the repo's CI, replace the `deploy` job with a `release` job that bumps
   the relevant `*_IMAGE_TAG` in `versions.env` and dispatches `deploy` with
   `client_payload.services="<svc>"` (see quant-data-engine `ci.yml`).
4. Add `INFRA_REPO_TOKEN` to the repo secrets.
5. Push, watch the infra Deploy workflow, verify the container, then flip the
   table row to ✅.

> During migration, the infra `push` trigger only **validates** compose; it
> never auto-deploys. Real rollouts come from `repository_dispatch` (per
> service) so un-migrated services keep being deployed by their own pipelines
> without interference.
