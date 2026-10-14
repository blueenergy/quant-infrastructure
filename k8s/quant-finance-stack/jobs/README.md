# K8s one-shot Jobs and deploy wrappers

Ad-hoc **Batch Job** manifests and shell helpers live here. **Recurring schedules**
are defined under [`../base-workers/`](../base-workers/) (Argo CD / `deploy-quant-role.sh`).

Do not duplicate CronJob YAML in this folder; apply cron specs from `base-workers` only.

## Weekday timeline (Asia/Shanghai, production intent)

| Local time | Component | Where configured |
|------------|-----------|------------------|
| 15:00–18:00+ | Market data sync (Tushare dispatcher, daily K, etc.) | `quant-data-engine/crontab.txt` inside `quant-data-engine` Pod |
| ~19:00 | Rule scores → `stock_scores` | `quant-scorer` Deployment ([base-workers/quant-scorer.yaml](../base-workers/quant-scorer.yaml)); see [apps/README.md](../../../apps/README.md#daily-scorer-runtime) |
| 20:00 | Canonical ML snapshots (hs300, a500) + Shadow | CronJob `quant-ml-daily-shadow-pipeline` ([base-workers/quant-ml-daily-shadow-pipeline-cronjob.yaml](../base-workers/quant-ml-daily-shadow-pipeline-cronjob.yaml)) |

ML pipeline **depends on scorer**, not on invoking data-engine scripts directly.

## Scripts

| Script | Purpose |
|--------|---------|
| [run-daily-ml-shadow-pipeline.sh](run-daily-ml-shadow-pipeline.sh) | `--apply-cron` / `--run-once` for the 20:00 pipeline (trainer image from `apps/versions.env`) |
| [run-quant-ml-materialize-snapshot.sh](run-quant-ml-materialize-snapshot.sh) | One-off materialize Job (uuid snapshot); add `--canonical` via env or extend script |
| [run-quant-model-shadow.sh](run-quant-model-shadow.sh) | Legacy shadow-only Cron (superseded; pipeline includes shadow) |
| [run-entry-filter-mvp-burst.sh](run-entry-filter-mvp-burst.sh) | Unrelated burst job |

## ML Shadow ops detail

See `quant-model-platform/docs/RUNBOOK_SHADOW.md` in the trading workspace.
