#!/usr/bin/env bash
# Switch rs0 member hosts from public IPs to VPC internal IPs (run on Primary / 180).
set -euo pipefail

PRIMARY_INTERNAL="${PRIMARY_INTERNAL:-192.168.200.59}"
SECONDARY_INTERNAL="${SECONDARY_INTERNAL:-192.168.201.16}"
PRIMARY_PUBLIC="${PRIMARY_PUBLIC:-180.184.28.170}"
SECONDARY_PUBLIC="${SECONDARY_PUBLIC:-115.190.172.95}"
MONGO_USER="${MONGO_USER:-admin}"
MONGO_PASSWORD="${MONGO_PASSWORD:-}"

usage() {
  cat <<'EOF'
Usage: reconfig-mongodb-replica-internal-ips.sh

Replaces public replica-set member hosts with internal VPC IPs.

If rs.status() on 115 still shows syncSourceHost: 180.184.28.170:27017,
the Primary member in rs.conf was not updated — run this on 180.

Environment:
  MONGO_USER / MONGO_PASSWORD   Admin credentials (required)
  PRIMARY_INTERNAL                Default: 192.168.200.59
  SECONDARY_INTERNAL              Default: 192.168.201.16
  PRIMARY_PUBLIC                  Default: 180.184.28.170
  SECONDARY_PUBLIC                Default: 115.190.172.95

Example (on 180):
  MONGO_PASSWORD='***' ./reconfig-mongodb-replica-internal-ips.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${MONGO_PASSWORD}" ]]; then
  echo "MONGO_PASSWORD is required." >&2
  usage
  exit 1
fi

mongosh --quiet -u "${MONGO_USER}" -p "${MONGO_PASSWORD}" --authenticationDatabase admin --eval "
function hostOf(ip) { return ip + ':27017'; }
const primaryInternal = hostOf('${PRIMARY_INTERNAL}');
const secondaryInternal = hostOf('${SECONDARY_INTERNAL}');
const publicHosts = new Set([
  hostOf('${PRIMARY_PUBLIC}'),
  hostOf('${SECONDARY_PUBLIC}'),
]);

const cfg = rs.conf();
print('Before reconfig:');
cfg.members.forEach(m => print('  member ' + m._id + ': ' + m.host));

let changed = false;
for (const m of cfg.members) {
  const old = m.host;
  if (old.startsWith('${PRIMARY_PUBLIC}')) {
    m.host = primaryInternal;
    changed = true;
  } else if (old.startsWith('${SECONDARY_PUBLIC}')) {
    m.host = secondaryInternal;
    changed = true;
  } else if (publicHosts.has(old)) {
    // exact match fallback
    m.host = old.includes('${PRIMARY_PUBLIC}') ? primaryInternal : secondaryInternal;
    changed = true;
  }
  if (m.host !== old) {
    print('  change: ' + old + ' -> ' + m.host);
  }
}

if (!changed) {
  print('No public member hosts to change.');
} else {
  cfg.version++;
  printjson(rs.reconfig(cfg));
}

print('');
print('After reconfig (rs.conf):');
rs.conf().members.forEach(m => print('  member ' + m._id + ': ' + m.host));

print('');
print('Member status + syncSourceHost:');
rs.status().members.forEach(m => {
  const line = m.name + '  ' + m.stateStr + '  health=' + m.health;
  if (m.syncSourceHost) {
    print(line + '  syncSourceHost=' + m.syncSourceHost);
  } else {
    print(line);
  }
});
"
