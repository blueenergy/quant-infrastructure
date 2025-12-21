#!/bin/bash
# 资源监控脚本

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
if docker exec quant-mongodb mongo --version > /dev/null 2>&1; then
    docker exec quant-mongodb mongo admin --quiet --eval "
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

# Redis 状态
echo "🔴 Redis Status:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if docker exec quant-redis redis-cli ping > /dev/null 2>&1; then
    docker exec quant-redis redis-cli INFO | grep -E "redis_version|uptime_in_seconds|used_memory_human|connected_clients|total_commands_processed" | while IFS=: read -r key value; do
        case $key in
            redis_version)
                echo "  Version: $value"
                ;;
            uptime_in_seconds)
                hours=$(echo "scale=2; $value / 3600" | bc)
                echo "  Uptime: $hours hours"
                ;;
            used_memory_human)
                echo "  Memory: $value"
                ;;
            connected_clients)
                echo "  Clients: $value"
                ;;
            total_commands_processed)
                echo "  Commands: $value"
                ;;
        esac
    done
else
    echo "  ❌ Redis not running"
fi
echo ""

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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
