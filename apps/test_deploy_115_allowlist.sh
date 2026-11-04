#!/usr/bin/env bash
# Unit tests for the 115 edge-node allowlist gate in deploy.sh.
#
# 115 must run only quant-api + quant-web (Mongo/Portainer live in the infra
# compose project and are not part of this service list). These tests cover the
# pure filtering logic; the container-removal guard is exercised on the host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILS=0

fail() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

pass() { echo "ok: $*"; }

with_env() {
  local host_profile="${1:-}"
  local body="$2"
  if (
    unset COMPOSE_PROFILES || true
    envfile="$(mktemp)"
    trap 'rm -f "$envfile"' EXIT
    [ -n "$host_profile" ] && echo "COMPOSE_HOST_PROFILE=${host_profile}" > "$envfile"
    export DEPLOY_COMMON_ENV="$envfile"
    # shellcheck source=deploy.sh
    source "$ROOT/deploy.sh"
    eval "$body"
  ); then
    return 0
  fi
  return 1
}

echo "== 115 allowlist"

if with_env "115" '
  SERVICES=()
  filter_services_on_115
  [ "${#SERVICES[@]}" -eq 2 ]
  [ "${SERVICES[0]}" = "quant-api" ]
  [ "${SERVICES[1]}" = "quant-web" ]
'; then
  pass "bare deploy.sh on 115 targets only the allowlist"
else
  fail "115 bare deploy should expand to allowlist"
fi

if with_env "115" '
  SERVICES=(quant-scorer)
  filter_services_on_115
  [ "${#SERVICES[@]}" -eq 0 ]
'; then
  pass "115 drops an explicit worker target"
else
  fail "115 explicit worker should be dropped"
fi

if with_env "115" '
  SERVICES=(quant-api quant-scorer quant-web quant-analyzer)
  filter_services_on_115
  [ "${#SERVICES[@]}" -eq 2 ]
  [ "${SERVICES[0]}" = "quant-api" ]
  [ "${SERVICES[1]}" = "quant-web" ]
'; then
  pass "115 keeps only allowlisted services and preserves order"
else
  fail "115 mixed list should keep api/web"
fi

if with_env "" '
  SERVICES=(quant-scorer)
  filter_services_on_115
  [ "${#SERVICES[@]}" -eq 1 ]
  [ "${SERVICES[0]}" = "quant-scorer" ]
'; then
  pass "non-115 hosts are unaffected"
else
  fail "non-115 filter must be a no-op"
fi

if with_env "115" '
  _is_allowed_service_on_115 quant-api && _is_allowed_service_on_115 quant-web
  ! _is_allowed_service_on_115 quant-data-engine
'; then
  pass "allowlist membership"
else
  fail "allowlist membership"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
