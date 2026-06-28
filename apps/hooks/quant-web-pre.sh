#!/usr/bin/env bash
set -euo pipefail

# Keep current production behavior from quantFinance-dashboard CI:
# quant-web talks to quant-api / MCP containers through quant-network, while
# those services may still be deployed outside this compose stack during the
# migration.
docker network inspect quant-network >/dev/null 2>&1 || docker network create quant-network

for container in quant-api quant-mcp-read quant-mcp-actions; do
  docker network connect quant-network "$container" 2>/dev/null || true
done
