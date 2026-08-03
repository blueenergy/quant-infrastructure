# KEDA

KEDA 2.20.2 is installed in the `keda` namespace via `install-keda.sh`.

**Nothing currently uses it.** There is no `ScaledObject` in this repo. It was
installed while evaluating queue-depth autoscaling for `backtest-worker`, and
left in place so the option is one manifest away. If that turns out to be the
wrong call, `./install-keda.sh --uninstall` removes it.

## Why backtest-worker is not autoscaled

The evaluation measured the real workload instead of assuming it, and the
numbers argued against autoscaling:

| Measurement | Value |
|---|---|
| Backtest task duration (p50 / p90 / max, 94 samples) | 0.04s / 0.2s / 1.1s |
| Tasks ever created | 97 |
| Largest batch | 28 tasks |
| Throughput of a single worker | ~25 tasks/second |
| Pod cold start | ~6s |

The largest batch in history is about one second of work for one worker. Even
the code's own ceiling of 500 tasks per compare batch (`MAX_COMPARE_TASKS`) is
roughly 20 seconds on a single replica. Scaling out to 8 pods to service that
would spend more time starting pods than running backtests, so the Deployment
stays at a fixed 2 replicas, which is already large overcapacity and gives
redundancy.

Job-per-task (`ScaledJob`) was considered and rejected for the same reason: a
6s pod start for a 40ms task.

Revisit this if the workload shape changes — routing full-market backtests
(thousands of symbols times several strategies) through the queue would put
tens of thousands of tasks in it, and that is where scaling out starts paying.

## If you do enable autoscaling later

Two things bit us during the evaluation; both are easy to miss.

**Argo CD and KEDA will fight over `spec.replicas`.** The `quant-aipoc-workers`
Application runs with `selfHeal: true`, so it reverts whatever KEDA just set.
Removing `replicas` from the Deployment is not enough on its own — also add to
the Application:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: backtest-worker
    jsonPointers:
      - /spec/replicas
syncPolicy:
  syncOptions:
    - RespectIgnoreDifferences=true
```

`deploy-quant-role.sh` also needs updating: it errors with "expected exactly one
replicas field" when `K8S_REPLICAS` is set and the manifest has no such field.

**`pollingInterval` and `cooldownPeriod` are inert unless `minReplicaCount` is
0.** KEDA warns about this on apply. With a non-zero minimum, scale-down speed
comes from `advanced.horizontalPodAutoscalerConfig.behavior`, not from
`cooldownPeriod`.

## Scaling signal, if needed

Count claimable pending tasks using the same filter the worker uses in
`claim_task`, so the signal matches what a new replica could actually pick up:

```json
{"status": "pending", "start_date": {"$nin": ["", null]}, "end_date": {"$nin": ["", null]}}
```

Credentials come from the existing `quant-secrets` secret:

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: backtest-mongo-auth
spec:
  secretTargetRef:
    - parameter: connectionString
      name: quant-secrets
      key: MONGO_URI
```

Do not treat expired leases (`status in (claimed, running)` with
`lease_expires_at < now`) as queue depth; they are an operator alert, and the
worker reclaims them on its own.
