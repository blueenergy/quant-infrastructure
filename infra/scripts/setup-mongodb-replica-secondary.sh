#!/usr/bin/env bash
# Start mongodb on 115 (compose override) as replica secondary and join rs0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_BASE="${COMPOSE_BASE:-docker-compose.yml}"
COMPOSE_OVERRIDE="${COMPOSE_OVERRIDE:-docker-compose.115.yml}"
PRIMARY_HOST="${PRIMARY_HOST:-180.184.28.170}"
SECONDARY_HOST="${SECONDARY_HOST:-115.190.172.95}"
REPL_SET_NAME="${REPL_SET_NAME:-rs0}"
MONGO_CONTAINER="${MONGO_CONTAINER:-quant-mongodb}"
KEYFILE_SRC="${KEYFILE_SRC:-/etc/mongodb-keyfile}"
KEYFILE_DST="${KEYFILE_DST:-${INFRA_DIR}/mongodb/keyfile}"
MONGO_USER="${MONGO_USER:-}"
MONGO_PASSWORD="${MONGO_PASSWORD:-}"
RESET_DATA="${RESET_DATA:-1}"

compose() {
  docker compose -f "${COMPOSE_BASE}" -f "${COMPOSE_OVERRIDE}" "$@"
}

usage() {
  cat <<'EOF'
Usage: setup-mongodb-replica-secondary.sh

Starts the standard mongodb service with docker-compose.115.yml override
(replica config + low memory). Same container/volume as future primary.

Environment:
  PRIMARY_HOST       Primary MongoDB host (default: 180.184.28.170)
  SECONDARY_HOST     Secondary host for rs.add (default: 115.190.172.95)
  COMPOSE_OVERRIDE   Override file (default: docker-compose.115.yml)
  KEYFILE_SRC/DST    keyFile paths
  MONGO_USER         Admin user (required)
  MONGO_PASSWORD     Admin password (required)
  RESET_DATA         1 to recreate empty volumes (default: 1)

Example:
  scp root@180.184.28.170:/etc/mongodb-keyfile ./mongodb/keyfile
  MONGO_USER=admin MONGO_PASSWORD='***' ./setup-mongodb-replica-secondary.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${MONGO_USER}" || -z "${MONGO_PASSWORD}" ]]; then
  echo "MONGO_USER and MONGO_PASSWORD are required." >&2
  usage
  exit 1
fi

cd "${INFRA_DIR}"

if [[ ! -f "${COMPOSE_OVERRIDE}" ]]; then
  echo "Missing ${INFRA_DIR}/${COMPOSE_OVERRIDE}" >&2
  exit 1
fi

if [[ ! -f "${KEYFILE_DST}" ]]; then
  if [[ -f "${KEYFILE_SRC}" ]]; then
    install -m 400 "${KEYFILE_SRC}" "${KEYFILE_DST}"
  else
    echo "Missing keyFile at ${KEYFILE_DST}. Copy it from the primary first." >&2
    exit 1
  fi
fi
chmod 400 "${KEYFILE_DST}"

if [[ ! -f .env ]]; then
  echo "Missing ${INFRA_DIR}/.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

# Remove legacy separate replica container if present.
if docker ps -a --format '{{.Names}}' | grep -qx quant-mongodb-replica; then
  echo "Removing legacy quant-mongodb-replica container..."
  docker rm -f quant-mongodb-replica 2>/dev/null || true
fi

echo "Pulling mongo:7.0..."
compose pull mongodb

if [[ "${RESET_DATA}" == "1" ]]; then
  echo "Recreating empty MongoDB volumes for initial sync..."
  compose down mongodb || true
  docker volume rm \
    quant-infrastructure_mongodb7_data \
    quant-infrastructure_mongodb7_config \
    quant-infrastructure_mongodb_replica_data \
    quant-infrastructure_mongodb_replica_config 2>/dev/null || true
fi

echo "Starting mongodb with ${COMPOSE_OVERRIDE}..."
compose up -d mongodb

for _ in $(seq 1 30); do
  if docker exec "${MONGO_CONTAINER}" mongosh --quiet -u "${MONGO_USERNAME:-admin}" -p "${MONGO_PASSWORD:-changeme}" --authenticationDatabase admin --eval "db.adminCommand('ping').ok" 2>/dev/null | grep -q 1; then
    break
  fi
  sleep 2
done

echo "Requesting primary to add secondary member..."
mongosh --quiet "mongodb://${PRIMARY_HOST}:27017/admin" \
  -u "${MONGO_USER}" -p "${MONGO_PASSWORD}" --authenticationDatabase admin --eval "
const memberHost = '${SECONDARY_HOST}:27017';
const cfg = rs.conf();
const exists = (cfg.members || []).some(m => m.host === memberHost);
if (exists) {
  print('Member already present: ' + memberHost);
  quit(0);
}
const res = rs.add({ host: memberHost, priority: 0, votes: 0 });
printjson(res);
"

echo "Waiting for secondary to join..."
for _ in $(seq 1 60); do
  state="$(mongosh --quiet "mongodb://${PRIMARY_HOST}:27017/admin" \
    -u "${MONGO_USER}" -p "${MONGO_PASSWORD}" --authenticationDatabase admin --eval "
const m = rs.status().members.find(x => x.name === '${SECONDARY_HOST}:27017');
print(m ? m.stateStr : 'UNKNOWN');
" 2>/dev/null || true)"
  echo "  ${SECONDARY_HOST}: ${state}"
  if [[ "${state}" == "SECONDARY" ]]; then
    echo "Secondary joined replica set ${REPL_SET_NAME}."
    exit 0
  fi
  sleep 10
done

echo "Secondary did not reach SECONDARY state in time. Check rs.status() on primary." >&2
exit 1
