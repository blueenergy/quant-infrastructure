#!/usr/bin/env bash
# Unit tests for deploy.sh trader mailbox guard (2026-11-06).
#
# The guard exists because a trader container bound to the wrong bqbox starts
# cleanly, then crash-loops on `file rpc timeout: ping`. Missed twice:
# 2026-10-31 and 2026-11-06 (both times the local overlay was dropped).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILS=0

fail() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

pass() { echo "ok: $*"; }

# Run a body in a subshell with a fake `docker inspect`. The body may override
# E_MAILBOX / D_MAILBOX to simulate a wrong mount.
run_body() {
  local body="$1"
  (
    # shellcheck source=deploy.sh
    source "$ROOT/deploy.sh"
    docker() {
      local verb="$1" container="$2"
      [ "$verb" = "inspect" ] || return 1
      case "$container" in
        quant-trader) echo -n "${E_MAILBOX:-/mnt/e/国金QMT交易端模拟/bin.x64/bqbox}" ;;
        quant-trader-live) echo -n "${D_MAILBOX:-/mnt/d/国金证券QMT交易端/bin.x64/bqbox}" ;;
        *) return 1 ;;
      esac
    }
    eval "$body"
  ) 2>&1 || true
}

echo "== check_trader_mailboxes"

out="$(run_body 'SERVICES=(quant-trader quant-trader-live); check_trader_mailboxes')"
if printf '%s' "$out" | grep -q "WARN"; then
  fail "correct mounts should not warn: $out"
else
  pass "correct mounts pass silently"
fi

out="$(run_body 'SERVICES=(quant-trader); E_MAILBOX=/mnt/d/国金QMT交易端模拟/bin.x64/bqbox; check_trader_mailboxes')"
if printf '%s' "$out" | grep -q "quant-trader: /app/bqbox -> /mnt/d/"; then
  pass "sim mounted on D: drive is flagged"
else
  fail "sim mounted on D: drive should be flagged: $out"
fi

out="$(run_body 'SERVICES=(quant-trader-live); D_MAILBOX=/mnt/e/国金QMT交易端模拟/bin.x64/bqbox; check_trader_mailboxes')"
if printf '%s' "$out" | grep -q "quant-trader-live: /app/bqbox -> /mnt/e/"; then
  pass "live mounted on E: drive is flagged"
else
  fail "live mounted on E: drive should be flagged: $out"
fi

out="$(run_body 'SERVICES=(quant-api); check_trader_mailboxes')"
if printf '%s' "$out" | grep -q "WARN"; then
  fail "unrelated service should not be checked: $out"
else
  pass "unrelated service is skipped"
fi

out="$(run_body 'SERVICES=(quant-trader); docker() { return 1; }; check_trader_mailboxes')"
if printf '%s' "$out" | grep -q "targeted but no /app/bqbox mount"; then
  pass "targeted missing container is reported"
else
  fail "targeted missing container should be reported: $out"
fi

out="$(run_body 'SERVICES=(); docker() { return 1; }; check_trader_mailboxes')"
if printf '%s' "$out" | grep -q "WARN"; then
  fail "full deploy should skip absent profile-gated containers: $out"
else
  pass "full deploy skips absent containers"
fi

echo
if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
