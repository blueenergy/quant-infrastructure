#!/usr/bin/env bash
# Unit tests for deploy.sh MCP profile gating (default-on except 115).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILS=0

fail() {
  echo "FAIL: $*" >&2
  FAILS=$((FAILS + 1))
}

pass() { echo "ok: $*"; }

# Each case runs in a subshell so COMPOSE_PROFILES / SERVICES do not leak,
# and so sourcing deploy.sh does not invoke main.
with_env() {
  local host_profile="${1:-}"
  local file_profiles="${2:-}"
  local body="$3"
  if (
    unset COMPOSE_PROFILES || true
    envfile="$(mktemp)"
    trap 'rm -f "$envfile"' EXIT
    {
      [ -n "$host_profile" ] && echo "COMPOSE_HOST_PROFILE=${host_profile}"
      [ -n "$file_profiles" ] && echo "COMPOSE_PROFILES=${file_profiles}"
    } > "$envfile"
    export DEPLOY_COMMON_ENV="$envfile"
    # shellcheck source=deploy.sh
    source "$ROOT/deploy.sh"
    eval "$body"
  ); then
    return 0
  fi
  return 1
}

echo "== apply_mcp_profile"

if with_env "" "" '
  COMPOSE_PROFILES="research-local"
  apply_mcp_profile
  _csv_has_profile mcp "$COMPOSE_PROFILES"
'; then
  pass "non-115 appends mcp to existing profiles"
else
  fail "non-115 appends mcp"
fi

if with_env "" "" '
  unset COMPOSE_PROFILES || true
  apply_mcp_profile
  _csv_has_profile mcp "${COMPOSE_PROFILES:-}"
'; then
  pass "non-115 empty profiles becomes mcp"
else
  fail "non-115 empty -> mcp"
fi

if with_env "115" "" '
  COMPOSE_PROFILES="research-local,mcp,scorer-local"
  apply_mcp_profile
  if _csv_has_profile mcp "$COMPOSE_PROFILES"; then exit 1; fi
  _csv_has_profile research-local "$COMPOSE_PROFILES"
  _csv_has_profile scorer-local "$COMPOSE_PROFILES"
'; then
  pass "115 strips mcp but keeps other profiles"
else
  fail "115 strips mcp"
fi

if with_env "115" "" '
  COMPOSE_PROFILES="mcp"
  apply_mcp_profile
  [ -z "${COMPOSE_PROFILES:-}" ]
'; then
  pass "115 with only mcp leaves profiles empty"
else
  fail "115 only-mcp -> empty"
fi

echo "== resolve_local_runtime_profiles"

if with_env "" "" '
  unset COMPOSE_PROFILES || true
  resolve_local_runtime_profiles
  _csv_has_profile mcp "$COMPOSE_PROFILES"
  _csv_has_profile research-local "$COMPOSE_PROFILES"
'; then
  pass "derived profiles include mcp on non-115"
else
  fail "resolve non-115 mcp"
fi

if with_env "115" "research-local,mcp,scorer-local" '
  unset COMPOSE_PROFILES || true
  resolve_local_runtime_profiles
  if _csv_has_profile mcp "$COMPOSE_PROFILES"; then exit 1; fi
  _csv_has_profile research-local "$COMPOSE_PROFILES"
'; then
  pass "common.env COMPOSE_PROFILES mcp is stripped on 115"
else
  fail "resolve 115 strip"
fi

if with_env "115" "" '
  export COMPOSE_PROFILES="research-local,mcp"
  resolve_local_runtime_profiles
  if _csv_has_profile mcp "$COMPOSE_PROFILES"; then exit 1; fi
'; then
  pass "pre-exported COMPOSE_PROFILES mcp is stripped on 115"
else
  fail "env COMPOSE_PROFILES 115"
fi

echo "== expand / filter services"

if with_env "" "" '
  SERVICES=(quant-api)
  expand_mcp_services
  [ "${#SERVICES[@]}" -eq 3 ]
  [ "${SERVICES[1]}" = "quant-mcp-read" ]
  [ "${SERVICES[2]}" = "quant-mcp-actions" ]
'; then
  pass "non-115 quant-api roll also includes both MCP services"
else
  fail "expand quant-api"
fi

if with_env "" "" '
  SERVICES=(quant-web)
  expand_mcp_services
  [ "${#SERVICES[@]}" -eq 1 ]
  [ "${SERVICES[0]}" = "quant-web" ]
'; then
  pass "non-115 unrelated service is not expanded"
else
  fail "expand unrelated"
fi

if with_env "115" "" '
  SERVICES=(quant-api)
  expand_mcp_services
  [ "${#SERVICES[@]}" -eq 1 ]
'; then
  pass "115 quant-api roll does not add MCP"
else
  fail "expand 115"
fi

if with_env "115" "" '
  SERVICES=(quant-api quant-mcp-read quant-mcp-actions quant-scheduler)
  filter_mcp_services_on_115
  [ "${#SERVICES[@]}" -eq 2 ]
  [ "${SERVICES[0]}" = "quant-api" ]
  [ "${SERVICES[1]}" = "quant-scheduler" ]
'; then
  pass "115 drops MCP from an explicit service list"
else
  fail "filter 115"
fi

if with_env "" "" '
  SERVICES=(quant-api quant-mcp-read)
  filter_mcp_services_on_115
  [ "${#SERVICES[@]}" -eq 2 ]
'; then
  pass "non-115 keeps MCP in the service list"
else
  fail "filter non-115"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS test(s) failed" >&2
  exit 1
fi
echo "all tests passed"
