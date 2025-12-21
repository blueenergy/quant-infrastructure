#!/bin/bash
# 部署脚本 - 启动量化交易基础设施

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Deploying Quant Trading Infrastructure"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

# 检查 Docker Compose（新版本作为 docker 子命令）
if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose is not available. Please install Docker Compose plugin."
    exit 1
fi

# 检查 .env 文件
if [ ! -f .env ]; then
    echo "⚠️  .env file not found. Creating from .env.example..."
    cp .env.example .env
    echo ""
    echo "⚠️  IMPORTANT: Please edit .env and change default passwords!"
    echo "   Run: vim .env"
    echo ""
    read -p "Press Enter after you have updated .env file..."
fi

# 确认部署
echo "📋 Deployment Configuration:"
echo "  • MongoDB: mongo:6.0"
echo "  • Redis: redis:7-alpine"
echo "  • Memory Limits:"
echo "    - MongoDB: 1.5GB (reserved: 800MB)"
echo "    - Redis: 512MB (reserved: 100MB)"
echo ""
read -p "Continue with deployment? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

# 拉取镜像
echo ""
echo "📥 Pulling Docker images..."
docker compose pull

# 启动服务
echo ""
echo "🔧 Starting services..."
docker compose up -d mongodb redis

# 等待服务就绪
echo ""
echo "⏳ Waiting for services to be ready..."
sleep 15

# 健康检查
echo ""
echo "🏥 Health check..."
echo ""

# 检查 MongoDB
echo -n "  MongoDB... "
if docker exec quant-mongodb mongo --eval "db.adminCommand('ping')" --quiet > /dev/null 2>&1; then
    echo "✅"
else
    echo "❌ MongoDB is not responding"
    echo ""
    echo "Logs:"
    docker-compose logs mongodb
    exit 1
fi

# 检查 Redis
echo -n "  Redis... "
if docker exec quant-redis redis-cli ping 2>/dev/null | grep -q PONG; then
    echo "✅"
else
    echo "❌ Redis is not responding"
    echo ""
    echo "Logs:"
    docker-compose logs redis
    exit 1
fi

# 显示容器状态
echo ""
echo "📊 Container Status:"
docker compose ps

# 显示资源使用
echo ""
echo "💾 Resource Usage:"
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" quant-mongodb quant-redis

# 成功提示
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎉 Infrastructure deployed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📡 Service Endpoints:"
echo "  • MongoDB: mongodb://localhost:27017"
echo "  • Redis:   redis://localhost:6379"
echo ""
echo "🔐 Default Credentials (change in .env):"
echo "  • MongoDB: admin / changeme-use-strong-password"
echo "  • Redis:   (password in .env)"
echo ""
echo "📖 Useful Commands:"
echo "  • View logs:    docker compose logs -f"
echo "  • Stop:         docker compose stop"
echo "  • Restart:      docker compose restart"
echo "  • Clean up:     docker compose down -v"
echo "  • Monitor:      ./scripts/monitor.sh"
echo ""
