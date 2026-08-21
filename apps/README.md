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
   apps/env/*.env            production runtime (NOT committed)
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
| `docker-compose.yml` | yes | **Production** topology. All images use `${*_IMAGE_TAG:-latest}`. |
| `docker-compose.dev.yml` | yes | **Local dev** stack (build from sibling repos). |
| `compose-dev.sh` | yes | Wrapper: `docker-compose.dev.yml` + **`apps/.env`** interpolation (dev). |
| `versions.env` | yes | Desired image tags (the "values.yaml"). CI edits this. |
| `CHANGELOG.md` | yes | Production deploy history (auto-appended by app CI). |
| `.env.example` | yes | **Dev-only** template for compose `${VAR}` interpolation; copy to `.env`. |
| `.env` | **no** (gitignored) | Local dev compose interpolation (`compose-dev.sh` default). |
| `env/common.env` | **no** (gitignored) | **Production** runtime config shared by all services. |
| `env/<svc>.env` | **no** (gitignored) | **Production** per-service runtime config & secrets. |
| `env/*.env.example` | yes | Templates for production `env/*.env` (copied on the host). |
| `deploy.sh` | yes | CD entrypoint, runs on the prod host. |
| `hooks/<svc>-{pre,post}.sh` | yes (optional) | Per-service deploy hooks (e.g. quant-api DB index migrations). |

## Release notes (`CHANGELOG.md` + bump commits)

Each app repo's CI `release` job calls `scripts/bump-versions-env.sh` after
pushing an image. The script:

1. Reads the previous tag from `versions.env`.
2. Collects `git log` from the app repo between old and new SHA.
3. Commits `versions.env` + prepends an entry to `apps/CHANGELOG.md`.
4. Writes a multi-line commit message (source repo, compare URL, change list).

Example bump commit subject: `deploy(quant-api): sha-08e3406`. The body lists
every commit since the last production tag so infra reviewers see what went
live without opening each app repo.

**Rollout order:** merge and push `quant-infrastructure` (script + changelog
header) to `main` *before* merging app CI changes — app workflows checkout
infra from `main` and invoke the script from that checkout.

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

## Env files: dev vs production

| File | When | Role |
|---|---|---|
| `apps/.env` | **Local dev** (`compose-dev.sh`) | Small shared file: `${VAR}` for Mongo, JWT, TUSHARE, etc. Service-specific keys stay in `<repo>/.env`. |
| `env/common.env` + `env/<svc>.env` | **Production** | Injected into containers via `env_file` on `docker-compose.yml`. |
| `<repo>/.env` (e.g. `stock-scoring-system/.env`) | **Local dev** | Service-specific runtime vars via `env_file` in `docker-compose.dev.yml`. Keys also listed under `environment: - KEY=${KEY}` take values from **`apps/.env`**, not the repo file. |

## Local development (full stack)

Use **`docker-compose.dev.yml`** — not `deploy.sh` and not production `docker-compose.yml`.

```bash
# Infra network + Mongo/Redis (once)
cd ../infra && docker compose up -d mongodb redis

cd ~/trading/quant-infrastructure/apps
cp -n .env.example .env   # first time; edit secrets
./compose-dev.sh config          # render check
./compose-dev.sh up -d --build quant-api quant-researcher
./compose-dev.sh --profile frontend up -d quant-web
# research-local and scorer-local are on by default via COMPOSE_PROFILES.
```

## Daily scorer runtime

`quant-scorer` runs the weekday 19:00 scoring schedule. Run exactly one
scheduler per database: its `flock` is local to one container/Pod and does not
prevent duplicate work across hosts.

For local Compose, keep:

```bash
QUANT_SCORER_RUNTIME=local_docker
COMPOSE_PROFILES=research-local,scorer-local
```

For Kubernetes, set `QUANT_SCORER_RUNTIME=external_k8s`, remove
`scorer-local` from `COMPOSE_PROFILES`, then stop the Compose service. Production
`deploy.sh` performs that stop/removal automatically; for dev use:

```bash
./compose-dev.sh --profile scorer-local stop quant-scorer
./compose-dev.sh --profile scorer-local rm -f quant-scorer
```

Deploy the singleton K8s scheduler from an FCI-connected host:

```bash
K8S_NAMESPACE=aipoc \
  k8s/quant-finance-stack/deploy-quant-role.sh scorer
```

The helper resolves the ACR repository from `apps/.env` and the immutable tag
from `apps/versions.env`. The default Pod uses one replica, a `Recreate`
strategy, `MAX_WORKERS=12`, and a 12-CPU/16-GiB limit. Do not scale replicas
without first adding a distributed scoring lock or explicit work sharding.

## Portfolio research runtime

Research jobs live in Mongo (`quant_trading.portfolio_research_jobs`). The
**API/UI** can stay on Compose while **workers** run either on the same host
or on Kubernetes. Pick one worker location per environment — do not run both
against the same queue.

| `PORTFOLIO_RESEARCH_RUNTIME` | Compose `quant-researcher` | Workers |
|---|---|---|
| `local_docker` (default) | Started via profile `research-local` | This host |
| `external_k8s` | Not started (`COMPOSE_PROFILES` omits `research-local`) | `k8s/.../quant-researcher.yaml` |

**Local Docker (default)**

```bash
# apps/.env
PORTFOLIO_RESEARCH_RUNTIME=local_docker
QUANT_SCORER_RUNTIME=local_docker
COMPOSE_PROFILES=research-local,scorer-local

./compose-dev.sh up -d quant-researcher
# or any up that includes the research-local profile
```

**External K8s**

1. On the Compose host (`apps/.env` or production `env/common.env`):

```bash
PORTFOLIO_RESEARCH_RUNTIME=external_k8s
# Keep scorer-local unless QUANT_SCORER_RUNTIME is also external_k8s.
COMPOSE_PROFILES=scorer-local
```

2. Stop any local researcher still running:

```bash
./compose-dev.sh --profile research-local stop quant-researcher   # dev
# prod: deploy.sh stops/removes it automatically before skipping the profile
```

3. Deploy only the researcher (draft; still ⚠️ not production-validated).
   Configure the K8s image repository in `apps/.env`; the deploy script reads
   its immutable tag from `apps/versions.env` (`QUANT_SCORER_IMAGE_TAG`):

```bash
# Needs Secret quant-secrets (MONGO_URI/MONGO_DB).
# The default ACR repository currently permits anonymous image pulls.
# apps/.env:
# QUANT_SCORER_IMAGE_REPOSITORY=crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com/wukongquant/quant-scorer
K8S_NAMESPACE=aipoc \
  k8s/quant-finance-stack/deploy-quant-role.sh researcher
```

   Use `--render` to inspect the resolved manifest without changing the
   cluster. Do not apply `base/quant-researcher.yaml` directly: its image is
   intentionally a neutral placeholder.

4. Ensure `quant-secrets` `MONGO_URI` reaches the same DB as Compose.
   With `PORTFOLIO_RESEARCH_RUNTIME=external_k8s`, artifacts upload to S3 bucket
   **`aipoc`** (see `PORTFOLIO_RESEARCH_S3_*` in `secret.env.example` and
   `apps/env/common.env.example`). Compose **quant-api** needs the same S3 read
   credentials so the UI can open HTML/combo detail without shared PVC.

   Create the bucket once on a host that reaches eecloud S3:

```bash
s3cmd -c deployment/credentials/s3cfg mb s3://aipoc
```

**Tuning**

- Single job sweep parallelism: `PORTFOLIO_RESEARCH_SWEEP_WORKERS` (Compose:
  `stock-scoring-system/.env` / `env/quant-scorer.env`; K8s default `1`).
- Multi-job parallelism: scale K8s `replicas` (each Pod gets a unique
  `PORTFOLIO_RESEARCH_WORKER_ID` from the Pod name). Prefer replicas over
  raising sweep workers to limit OOM risk.

**Env model (dev only):**

| Layer | Purpose |
|---|---|
| `apps/.env` | Compose `${VAR}` interpolation via `compose-dev.sh --env-file` |
| Each service `env_file` | Runtime config from the owning repo (e.g. `stock-scoring-system/.env` → `PORTFOLIO_RESEARCH_SWEEP_WORKERS`) |
| `environment:` in compose | Docker-network overrides (`MONGO_URI` from `DOCKER_MONGO_URI`, feature flags) |

Do **not** run dev and production stacks with the same `container_name` on one host (e.g. `quant-api`). Use project `quantfinance-dev` from `compose-dev.sh` only after stopping the old stack, or adjust `container_name` for local experiments.

**Note:** `quant-assistant` is not part of the dev stack (legacy assistant retired). `quant-web` builds with `VITE_ASSISTANT_STREAM_BACKEND=hermes` and routes chat through quant-api.

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
| quant-api / mcp / scheduler | `QUANT_API_IMAGE_TAG` | ✅ |
| quant-web | `QUANT_DASHBOARD_IMAGE_TAG` | ✅ |
| quant-scorer | `QUANT_SCORER_IMAGE_TAG` | ✅ |
| quant-researcher | `QUANT_SCORER_IMAGE_TAG` | ✅ |
| quant-portfolio | `QUANT_SCORER_IMAGE_TAG` | ✅ |
| backtest-worker | `BACKTEST_WORKER_IMAGE_TAG` | ✅ |
| quant-analyzer | `QUANT_ANALYZER_IMAGE_TAG` | ✅ |
| quant-strategy-manager | `QUANT_STRATEGY_MANAGER_IMAGE_TAG` | ✅ |

`quant-scorer`、`quant-researcher`、`quant-portfolio` 共享同一个
`stock-scoring-system` 镜像 tag，通过不同 `command` 分别运行评分、组合研究、
组合计划/paper-trading 入口。

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
   the relevant `*_IMAGE_TAG` in `versions.env` via
   `scripts/bump-versions-env.sh` (release notes + `CHANGELOG.md`) and
   dispatches `deploy` with `client_payload.services="<svc>"` (see
   quant-data-engine `ci.yml`).
4. Add `INFRA_REPO_TOKEN` to the repo secrets.
5. Push, watch the infra Deploy workflow, verify the container, then flip the
   table row to ✅.

> During migration, the infra `push` trigger only **validates** compose; it
> never auto-deploys. Real rollouts come from `repository_dispatch` (per
> service) so un-migrated services keep being deployed by their own pipelines
> without interference.
