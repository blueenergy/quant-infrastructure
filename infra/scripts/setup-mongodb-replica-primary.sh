#!/usr/bin/env bash
# Configure systemd MongoDB on the primary host as replica set rs0.
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:-192.168.200.59}"
REPL_SET_NAME="${REPL_SET_NAME:-rs0}"
KEYFILE_PATH="${KEYFILE_PATH:-/etc/mongodb-keyfile}"
MONGOD_CONF="${MONGOD_CONF:-/etc/mongod.conf}"
MONGO_USER="${MONGO_USER:-}"
MONGO_PASSWORD="${MONGO_PASSWORD:-}"

usage() {
  cat <<'EOF'
Usage: setup-mongodb-replica-primary.sh

Environment:
  PRIMARY_HOST     VPC host used in rs.initiate (default: 192.168.200.59)
  REPL_SET_NAME    Replica set name (default: rs0)
  KEYFILE_PATH     Shared keyFile path (default: /etc/mongodb-keyfile)
  MONGOD_CONF      mongod config path (default: /etc/mongod.conf)
  MONGO_USER       Admin user for rs.initiate (required)
  MONGO_PASSWORD   Admin password (required)

Example:
  MONGO_USER=admin MONGO_PASSWORD='***' ./setup-mongodb-replica-primary.sh
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

if ! command -v mongosh >/dev/null 2>&1; then
  echo "mongosh is required on the primary host." >&2
  exit 1
fi

if [[ ! -f "${MONGOD_CONF}" ]]; then
  echo "Missing ${MONGOD_CONF}" >&2
  exit 1
fi

if [[ ! -f "${KEYFILE_PATH}" ]]; then
  echo "Generating keyFile at ${KEYFILE_PATH}"
  openssl rand -base64 756 > "${KEYFILE_PATH}"
  chmod 400 "${KEYFILE_PATH}"
  chown mongod:mongod "${KEYFILE_PATH}"
fi

backup_conf="${MONGOD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "${MONGOD_CONF}" "${backup_conf}"
echo "Backed up ${MONGOD_CONF} -> ${backup_conf}"

python3 - "${MONGOD_CONF}" "${KEYFILE_PATH}" "${REPL_SET_NAME}" <<'PY'
import sys
from pathlib import Path

conf_path = Path(sys.argv[1])
keyfile = sys.argv[2]
replset = sys.argv[3]
lines = conf_path.read_text().splitlines()

def strip_section(name: str) -> list[str]:
    out: list[str] = []
    skip = False
    for line in lines if name != "__all__" else []:
        pass
    return out

# Rebuild config while replacing security/replication blocks.
out: list[str] = []
skip_block = False
for line in lines:
    stripped = line.strip()
    if stripped.startswith("replication:") or stripped.startswith("security:"):
        skip_block = True
        continue
    if skip_block:
        if stripped and not line.startswith((" ", "\t")) and stripped.endswith(":"):
            skip_block = False
        else:
            continue
    out.append(line)

while out and not out[-1].strip():
    out.pop()

out.extend(
    [
        "",
        "security:",
        '  authorization: "enabled"',
        f"  keyFile: {keyfile}",
        "",
        "replication:",
        f"  replSetName: {replset}",
        "",
    ]
)
conf_path.write_text("\n".join(out))
PY

echo "Restarting mongod..."
systemctl restart mongod
sleep 8

if ! systemctl is-active --quiet mongod; then
  echo "mongod failed to start. Check: journalctl -u mongod -n 50" >&2
  exit 1
fi

mongosh --quiet -u "${MONGO_USER}" -p "${MONGO_PASSWORD}" --authenticationDatabase admin --eval "
const status = (() => {
  try { return rs.status(); } catch (e) { return null; }
})();
if (status && status.ok === 1) {
  print('Replica set already initialized: ' + status.set);
  quit(0);
}
const cfg = {
  _id: '${REPL_SET_NAME}',
  members: [{ _id: 0, host: '${PRIMARY_HOST}:27017', priority: 1 }]
};
const res = rs.initiate(cfg);
printjson(res);
"

echo "Primary replica set configuration complete."
echo "Copy ${KEYFILE_PATH} to the secondary host before starting Docker MongoDB."
