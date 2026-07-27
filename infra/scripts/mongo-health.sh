#!/usr/bin/env bash
# One-click MongoDB health / bottleneck scan (see mongo_health_check.py).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/mongo_health_check.py" "$@"
