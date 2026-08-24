#!/usr/bin/env bash
# Scheduled Cache Contract v2 coverage audit.
# Initialization is intentionally excluded: bootstrap missing rows manually.
set -euo pipefail

cd /app

STABILITY_SECONDS="${PORTFOLIO_RESEARCH_COVERAGE_AUDIT_STABILITY_SECONDS:-60}"
TTL_HOURS="${PORTFOLIO_RESEARCH_COVERAGE_AUDIT_TTL_HOURS:-24}"
AUDITED_BY="${PORTFOLIO_RESEARCH_COVERAGE_AUDIT_BY:-scheduled-coverage-audit}"
SCORING_LOCK_FILE="${SCORING_LOCK_FILE:-/tmp/stock-scoring.lock}"

before="$(mktemp)"
after="$(mktemp)"
trap 'rm -f "$before" "$after"' EXIT

# Never compete with the 19:00 scoring process. A still-running scorer makes
# this audit visibly fail; Supercronic records the non-zero exit and continues.
exec 9>"$SCORING_LOCK_FILE"
if ! flock -n 9; then
  echo "[cache-coverage-audit] ERROR: scoring lock is busy; refusing overlapping audit" >&2
  exit 1
fi

echo "[cache-coverage-audit] observing five sources for ${STABILITY_SECONDS}s"
python tools/ops/audit_portfolio_cache_sources.py >"$before"
sleep "$STABILITY_SECONDS"
python tools/ops/audit_portfolio_cache_sources.py >"$after"

python - "$before" "$after" <<'PY'
import json
import sys

EXPECTED = {
    "finance.stock_scores",
    "quant_data.volume_price",
    "quant_data.stock_adj_factor",
    "quant_data.index_constituents",
    "quant_data.sw_index_member",
}


def load_state(path):
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    inspection = payload.get("inspection") or {}
    sources = inspection.get("sources") or {}
    if set(sources) != EXPECTED:
        raise SystemExit(
            f"{path}: expected five sources, got {sorted(sources)}"
        )
    snapshot = inspection.get("snapshot") or {}
    if snapshot.get("active_sources"):
        raise SystemExit(
            f"{path}: active source mutations: {snapshot['active_sources']}"
        )

    state = {}
    for source in sorted(EXPECTED):
        row = sources[source]
        ledger = row.get("ledger") or {}
        active = ledger.get("active_mutations") or []
        if (
            not row.get("exists")
            or int(row.get("count") or 0) <= 0
            or row.get("ledger_missing")
            or ledger.get("state") != "committed"
            or active
        ):
            raise SystemExit(f"{path}: unhealthy source {source}: {row}")
        state[source] = {
            "revision": int(ledger["revision"]),
            "count": int(row["count"]),
            "watermark_field": row.get("watermark_field"),
            "watermark": row.get("watermark"),
        }
    return state


before = load_state(sys.argv[1])
after = load_state(sys.argv[2])
if before != after:
    changed = [
        source for source in sorted(EXPECTED) if before[source] != after[source]
    ]
    raise SystemExit(f"sources changed during stability window: {changed}")
print("five source revisions/counts/watermarks remained stable")
PY

audit_id="scheduled-$(date -u +%Y%m%dT%H%M%SZ)-${HOSTNAME:-unknown}"
echo "[cache-coverage-audit] marking coverage complete: ${audit_id}"
python tools/ops/audit_portfolio_cache_sources.py \
  --mark-complete \
  --audit-id "$audit_id" \
  --audited-by "$AUDITED_BY" \
  --ttl-hours "$TTL_HOURS" \
  --execute
echo "[cache-coverage-audit] completed successfully"
