# Quant Infrastructure

完整的量化交易基础设施部署方案，包含 MongoDB、Redis、监控系统。

## 📋 组件

- **MongoDB 6.0**: 主数据库，存储历史数据、交易信号、持仓等
- **Redis 7**: 内存数据库，用于实时 tick 数据缓存和 Pub/Sub
- **Prometheus** (可选): 监控系统
- **Grafana** (可选): 可视化面板

## 🚀 快速开始

### 0. 新服务器初始化 (首次部署)

如果是在全新服务器上部署，首先运行初始化脚本：

```bash
# 下载初始化脚本
curl -O https://raw.githubusercontent.com/.../setup-server.sh
# 或者如果已克隆仓库
cd quant-infrastructure

# 以 root 权限运行
sudo bash scripts/setup-server.sh
```

**该脚本会自动：**
- ✅ 创建 `shuyolin` 用户和组
- ✅ 配置 sudo 权限
- ✅ 创建项目目录结构 (`~/trading/...`)
- ✅ 设置文件权限
- ✅ 安装基础依赖 (Python3, Git, GCC 等)
- ✅ 配置防火墙端口 (27017, 6379, 5000, 3001, 5173)
- ✅ 安装 Docker (可选)
- ✅ 创建快速启动脚本

**运行后切换用户：**
```bash
su - shuyolin
```

### 1. 克隆仓库

```bash
cd ~/trading
git clone <repository-url> quant-infrastructure
cd quant-infrastructure
```

### 2. 配置环境变量

```bash
# 复制环境变量模板
cp .env.example .env

# 编辑并修改密码
vim .env
```

### 3. 部署服务

```bash
# 运行部署脚本
./scripts/deploy.sh

# 或者手动启动
docker-compose up -d
```

### 4. 验证部署

```bash
# 测试 MongoDB
mongo mongodb://admin:password@localhost:27017/finance

# 测试 Redis
redis-cli -h localhost -p 6379 ping
```

## 📡 服务访问

| 服务 | 地址 | 默认端口 |
|-----|------|---------|
| MongoDB | `mongodb://172.20.0.2:27017` | 27017 |
| Redis | `redis://172.20.0.3:6379` | 6379 |
| Prometheus | `http://localhost:9090` | 9090 |
| Grafana | `http://localhost:3000` | 3000 |

## 🔐 默认凭据

**MongoDB**:
- 用户名: `admin` (root)
- 密码: 在 `.env` 中设置
- 数据库: `finance`
- 应用用户: `quant_user`

**Redis**:
- 密码: 在 `.env` 中设置

**Grafana** (可选):
- 用户名: `admin`
- 密码: 在 `.env` 中设置

⚠️ **生产环境请务必修改默认密码！**

## 📊 资源限制

服务器要求: **4核4GB内存**

| 服务 | 最大内存 | 预留内存 | CPU限制 |
|-----|---------|---------|--------|
| MongoDB | 1.5GB | 800MB | 2核 |
| Redis | 512MB | 100MB | 0.5核 |
| Prometheus | 200MB | - | 0.5核 |
| Grafana | 200MB | - | 0.5核 |

## 🛠️ 常用命令

### 启动/停止

```bash
# 启动所有服务
docker compose up -d

# 只启动数据库（不启动监控）
docker compose up -d mongodb redis

# 启动监控（需要 --profile）
docker compose --profile monitoring up -d

# 停止服务
docker compose stop

# 重启服务
docker compose restart

# 停止并删除容器（保留数据）
docker compose down

# 停止并删除所有（包括数据卷）
docker compose down -v
```

### 查看日志

```bash
# 查看所有日志
docker compose logs -f

# 查看 MongoDB 日志
docker compose logs -f mongodb

# 查看 Redis 日志
docker compose logs -f redis

# 最近 100 行
docker compose logs --tail=100 mongodb
```

### 监控

```bash
# 查看容器状态
docker compose ps

# 查看资源使用
docker stats

# 运行监控脚本
./scripts/monitor.sh

# 持续监控
watch -n 5 ./scripts/monitor.sh
```

### 数据库操作

```bash
# 进入 MongoDB
docker exec -it quant-mongodb mongo -u admin -p password

# 进入 Redis
docker exec -it quant-redis redis-cli

# 查看 MongoDB 数据库
docker exec quant-mongodb mongo -u admin -p password --eval "show dbs"

# 查看集合
docker exec quant-mongodb mongo finance -u admin -p password --eval "show collections"

# Redis 信息
docker exec quant-redis redis-cli INFO
```

## 📂 目录结构

```
quant-infrastructure/
├── docker-compose.yml          # 主编排文件
├── .env.example                # 环境变量模板
├── .env                        # 环境变量（需自己创建）
├── mongodb/
│   ├── mongod.conf            # MongoDB 配置
│   └── mongo-init.js          # 初始化脚本
├── redis/
│   └── redis.conf             # Redis 配置
├── prometheus/
│   └── prometheus.yml         # Prometheus 配置
├── grafana/
│   ├── dashboards/            # Grafana 面板
│   └── datasources/           # 数据源配置
└── scripts/
    ├── deploy.sh              # 部署脚本
    ├── monitor.sh             # 监控脚本
    ├── backup.sh              # 备份脚本
    └── restore.sh             # 恢复脚本
```

## 🔗 业务系统集成

### quantFinance (后端API)

```bash
# quantFinance/.env
MONGO_URL=mongodb://admin:password@172.20.0.2:27017
MONGO_DB=finance
REDIS_URL=redis://:password@172.20.0.3:6379
```

### quant_data_engine (数据引擎)

```bash
# quant_data_engine/.env
MONGO_URL=mongodb://admin:password@172.20.0.2:27017
MONGO_DB=finance
REDIS_HOST=172.20.0.2
REDIS_PORT=6379
REDIS_PASSWORD=password
```

### stock-execution-system (策略系统)

```bash
# stock-execution-system/.env
MONGO_URL=mongodb://admin:password@172.20.0.2:27017
MONGO_DB=finance
REDIS_URL=redis://:password@172.20.0.3:6379
```

## 🔧 故障排查

### MongoDB 无法启动

```bash
# 查看日志
docker compose logs mongodb

# 检查配置文件
cat mongodb/mongod.conf

# 检查数据卷权限
docker volume inspect quant-infrastructure_mongodb_data
```

### Redis 无法连接

```bash
# 检查端口
docker compose ps
netstat -an | grep 6379

# 测试连接
docker exec quant-redis redis-cli ping
```

### 内存不足

```bash
# 查看内存使用
free -h
docker stats

# 调整内存限制
vim docker-compose.yml  # 修改 mem_limit
docker compose up -d
```

## 📈 性能优化

### MongoDB

- WiredTiger 缓存限制到 800MB
- 启用 zstd 压缩
- 索引前缀压缩
- 90天数据自动清理

### Redis

- LRU 淘汰策略
- AOF 持久化（每秒同步）
- 禁用 RDB 快照
- 数据结构优化（ziplist）

## 🔒 安全建议

1. **修改默认密码**: 编辑 `.env` 文件
2. **防火墙配置**: 限制端口访问
3. **SSL/TLS**: 生产环境启用加密连接
4. **定期备份**: 使用 `./scripts/backup.sh`
5. **监控告警**: 启用 Prometheus + Grafana

## 📝 维护

### 备份

```bash
# MongoDB 备份
./scripts/backup.sh

# 手动备份
docker exec quant-mongodb mongodump \
  -u admin -p password \
  --authenticationDatabase admin \
  --out /backup
```

### 恢复

```bash
# MongoDB 恢复
./scripts/restore.sh <backup_file>
```

### 清理

```bash
# 清理未使用的镜像
docker image prune -a

# 清理未使用的卷
docker volume prune

# 清理所有未使用资源
docker system prune -a --volumes
```

## 📞 支持

如有问题，请查看日志：
```bash
docker compose logs -f
```

## 📄 许可证

[Your License]
