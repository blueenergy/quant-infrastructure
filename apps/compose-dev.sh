#!/usr/bin/env bash
# Local full-stack development Compose wrapper.
# - Uses docker-compose.dev.yml (build from source)
# - Interpolates ${VAR} from apps/.env by default (see .env.example, DEV ONLY)
# - Per-service runtime config comes from each repo's .env via env_file in the compose file
# - COMPOSE_PROFILES from apps/.env (default research-local) gates quant-researcher;
#   see README "Portfolio research runtime" for local_docker vs external_k8s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_FILE="${COMPOSE_DEV_FILE:-docker-compose.dev.yml}"
ENV_FILE="${COMPOSE_DEV_ENV_FILE:-.env}"
PROJECT_NAME="${COMPOSE_DEV_PROJECT:-quantfinance-dev}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing compose interpolation env file: $SCRIPT_DIR/$ENV_FILE" >&2
  echo "Copy .env.example to .env in this directory, or set COMPOSE_DEV_ENV_FILE." >&2
  exit 1
fi

exec docker compose \
  -f "$COMPOSE_FILE" \
  --env-file "$ENV_FILE" \
  -p "$PROJECT_NAME" \
  "$@"
