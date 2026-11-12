#!/bin/bash
# 资源监控脚本

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    source "${SCRIPT_DIR}/.env"
    set +a
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Quant Infrastructure Resource Monitor"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 系统资源
echo "💻 System Resources:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
free -h
echo ""

# Docker 容器状态
echo "🐳 Docker Container Stats:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker stats --no-stream --format \
  "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"
echo ""

# MongoDB 状态
echo "🍃 MongoDB Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if docker exec quant-mongodb mongosh --version > /dev/null 2>&1; then
    docker exec quant-mongodb mongosh admin --quiet -u "${MONGO_USERNAME:-admin}" -p "${MONGO_PASSWORD:-changeme}" --authenticationDatabase admin --eval "
        var status = db.serverStatus();
        print('  Version: ' + status.version);
        print('  Uptime: ' + (status.uptime / 3600).toFixed(2) + ' hours');
        print('  Connections: ' + status.connections.current + ' / ' + status.connections.available);
        print('  Memory:');
        print('    Virtual: ' + (status.mem.virtual).toFixed(2) + ' MB');
        print('    Resident: ' + (status.mem.resident).toFixed(2) + ' MB');
        print('  Operations:');
        print('    Query: ' + status.opcounters.query);
        print('    Insert: ' + status.opcounters.insert);
        print('    Update: ' + status.opcounters.update);
        print('    Delete: ' + status.opcounters.delete);
    "
else
    echo "  ❌ MongoDB not running"
fi
echo ""

# Redis 已停用（2026-11-12），不再纳入监控；需要时 docker compose --profile redis up -d redis

# 磁盘使用
echo "💾 Disk Usage:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
df -h | grep -E "Filesystem|/dev/"
echo ""

# Docker 卷使用
echo "📦 Docker Volume Usage:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
docker system df -v | grep -A 10 "^VOLUME NAME"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💡 Tip: Run with 'watch -n 5' for continuous monitoring"
echo "   Example: watch -n 5 ./scripts/monitor.sh"
echo "   Mongo bottleneck scan: ./scripts/mongo-health.sh  (or --json)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
