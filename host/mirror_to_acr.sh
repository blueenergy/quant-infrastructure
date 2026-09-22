#!/bin/bash
# Mirror the newest sha-* images of each app repo from ghcr.io into Aliyun ACR.
# Runs on the host (cron), not in CI. See llm-wiki:
#   projects/trading/repos/stock-scoring-system/ci-acr-push-silent-hang
#
# Why this exists: the CI job pushes to ghcr AND ACR in one buildx step. ghcr
# finishes in 3.7s; the ACR leg silently hangs (18 minutes, zero log lines, then
# killed by the job timeout). The failure is in the cross-registry write over a
# cross-border link, so CI now pushes ghcr only and this script relays inward.
#
# Why classic pull/tag/push and NOT `buildx imagetools create`:
#   imagetools streams ghcr -> ACR while reading, over HTTP/2, with no retry.
#   Measured: PROTOCOL_ERROR after 6m55s. pull/tag/push is unidirectional, the
#   blobs land locally first, and a failed step can simply be run again.
#
# Note the relay pushes a single-platform (linux/amd64) manifest, not the
# multi-arch index CI built. Every consumer is x86_64 (compose services and the
# k8s overlays all pin amd64 nodes), so this is fine — and it is why arm64 was
# dropped from CI. docker says so out loud on push:
#   "Not all multiplatform-content is present and only the available
#    single-platform image was pushed"
#
# Usage:
#   ./mirror_to_acr.sh                            # sweep all, sync recent tags
#   ./mirror_to_acr.sh quant-analyzer             # one image only
#   ./mirror_to_acr.sh quant-analyzer sha-ab12cd3 # a specific tag (backfill)
#
# Exit: 0 = all in sync, 1 = something failed, 2 = previous run still active.

# No `set -e`: a failure on one image must not abort the sweep.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TRADING_ROOT=${TRADING_ROOT:-/home/shuyolin/trading}
ACR_REGISTRY=${ACR_REGISTRY:-crpi-gv3f6mfcrw75qane.cn-hangzhou.personal.cr.aliyuncs.com}
MAIN_BRANCH=${MAIN_BRANCH:-main}
LOCK=/tmp/mirror_to_acr.lock
LOG=${LOG:-$SCRIPT_DIR/mirror_to_acr.log}
LOG_MAX_BYTES=${LOG_MAX_BYTES:-5242880}
# How many recent commits per repo to cover. Every push to main starts its own
# release job, so two pushes minutes apart both build and both need their tag on
# ACR. The relay only ever sees the tip of main, so covering just the newest tag
# would strand the older one on ghcr and leave its release job polling until it
# gave up. 1 disables the catch-up; 3 covers ordinary burst pushes.
RECENT_TAGS=${RECENT_TAGS:-3}
# Cross-border read measured at ~300 KB/s (209 MB ≈ 12 min); push inside China
# measured at ~6.4 MB/s. Budget generously for the read, it is the only slow leg.
PULL_TIMEOUT=${PULL_TIMEOUT:-2400}
PUSH_TIMEOUT=${PUSH_TIMEOUT:-900}

# ACR repo | ghcr image | app repo directory (used to resolve the newest tag).
# The local directory name is spelled out because it does not always match the
# image name (stock-scoring-system -> quant-scorer, quantFinance -> quant-api).
IMAGE_MAP=(
  "wukongquant/quant-scorer|ghcr.io/blueenergy/stock-scoring-system|stock-scoring-system"
  "wukongquant/quant-api|ghcr.io/blueenergy/quant-api|quantFinance"
  "wukongquant/quant-dashboard|ghcr.io/blueenergy/quant-dashboard|quantFinance-dashboard"
  "wukongquant/quant-analyzer|ghcr.io/blueenergy/quant-analyzer|quantAnalyzer"
  "wukongquant/quant-data-engine|ghcr.io/blueenergy/quant-data-engine|quant-data-engine"
  "wukongquant/quant-strategy-manager|ghcr.io/blueenergy/quant-strategy-manager|quant-strategy-manager"
  "wukongquant/backtest-worker|ghcr.io/blueenergy/backtest-worker|backtest-worker"
)

# stderr, not stdout: stdout carries resolved tags and must stay clean. Both
# streams still land in the log file, and a manual run still prints to the
# terminal (cron discards both).
log() { local m="[$(date)] $*"; echo "$m" >> "$LOG"; echo "$m" >&2; }

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK"
  if ! flock -n 9; then
    log "Another mirror_to_acr run is active; skipping."
    exit 2
  fi
fi

# Keep the log bounded — this runs on a timer and only ever appends.
if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ]; then
  mv -f "$LOG" "$LOG.1"
fi

tag_exists() { docker buildx imagetools inspect "$1" >/dev/null 2>&1; }

# Resolve the newest $RECENT_TAGS tags from the app repo's origin/<main>, i.e.
# the same commits CI built. Reads origin/<main> rather than HEAD so a repo
# parked on a work branch still resolves correctly. Prints newest first.
resolve_tags() {
  local dir="$TRADING_ROOT/$1" sha
  if [ ! -d "$dir/.git" ]; then
    log "  x no local checkout at $dir"
    return 1
  fi
  if ! git -C "$dir" fetch --quiet origin "$MAIN_BRANCH" 2>/dev/null; then
    log "  x git fetch failed in $1"
    return 1
  fi
  git -C "$dir" log --format=%H -n "$RECENT_TAGS" "origin/$MAIN_BRANCH" 2>/dev/null \
    | while read -r sha; do
        [ -n "$sha" ] || continue
        # Plain truncation to 7, matching CI's ${GITHUB_SHA::7}. `git rev-parse
        # --short=7` can return more characters on an ambiguous prefix, which
        # would produce a tag that does not exist on ghcr.
        printf 'sha-%s\n' "${sha:0:7}"
      done
}

mirror_tag() {
  local acr_repo="$1" ghcr_image="$2" tag="$3"
  local acr_image="$ACR_REGISTRY/$acr_repo" src dst

  src="$ghcr_image:$tag"
  dst="$acr_image:$tag"

  if tag_exists "$dst"; then
    log "  = $acr_repo:$tag already on ACR"
    return 0
  fi
  if ! tag_exists "$src"; then
    # CI still running, or it failed for that commit. Best effort: the release
    # job is what raises an alarm about a tag that never arrives.
    log "  ~ $acr_repo:$tag not on ghcr yet; skipping"
    return 0
  fi

  log "  v pull $src (cross-border, can take ~15 min)"
  if ! timeout "$PULL_TIMEOUT" docker pull -q --platform linux/amd64 "$src"; then
    log "  x pull failed: $src"
    return 1
  fi
  docker tag "$src" "$dst" || { log "  x tag failed"; return 1; }

  log "  ^ push $dst"
  if ! timeout "$PUSH_TIMEOUT" docker push -q "$dst"; then
    log "  x push failed: $dst (ACR login expired?)"
    return 1
  fi
  # Verify at the destination — a push that reports success is not proof.
  if ! tag_exists "$dst"; then
    log "  x push reported success but $dst is not readable on ACR"
    return 1
  fi

  log "  + $acr_repo:$tag mirrored to ACR"
  return 0
}

mirror_repo() {
  local acr_repo="$1" ghcr_image="$2" app_dir="$3" tag="${4:-}"
  local -a tags=() rc=0 t

  if [ -n "$tag" ]; then
    tags=("$tag")
  else
    mapfile -t tags < <(resolve_tags "$app_dir")
    if [ "${#tags[@]}" = 0 ]; then
      log "  x could not resolve a tag for $app_dir"
      return 1
    fi
  fi

  for t in "${tags[@]}"; do
    mirror_tag "$acr_repo" "$ghcr_image" "$t" || rc=1
  done
  return $rc
}

main() {
  local want_key="${1:-}" want_tag="${2:-}"
  local entry acr_repo ghcr_image app_dir key
  local n_ok=0 n_fail=0 matched=0 rc=0

  log "=== mirror start${want_key:+ (only $want_key)} ==="

  for entry in "${IMAGE_MAP[@]}"; do
    IFS='|' read -r acr_repo ghcr_image app_dir <<<"$entry"
    key="${acr_repo##*/}"
    # Accept either the ACR name or the local directory name as the filter.
    if [ -n "$want_key" ] && [ "$want_key" != "$key" ] && [ "$want_key" != "$app_dir" ]; then
      continue
    fi
    matched=$((matched + 1))
    log "-> $key"
    if mirror_repo "$acr_repo" "$ghcr_image" "$app_dir" "$want_tag"; then
      n_ok=$((n_ok + 1))
    else
      n_fail=$((n_fail + 1))
      rc=1
    fi
  done

  if [ "$matched" = 0 ]; then
    log "x '$want_key' is not in IMAGE_MAP"
    rc=1
  fi

  log "=== mirror done: ok=$n_ok failed=$n_fail ==="
  return $rc
}

main "$@"
