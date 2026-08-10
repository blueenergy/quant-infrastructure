# MongoDB Replica Set: 180 (Primary) + 115 (Secondary)

灾备拓扑（**A + 7.0 Secondary**，115 未来扶正为 Primary）：

- **Primary**: `180.184.28.170`，systemd MongoDB **6.0**
- **Secondary**: `115.190.172.95`，Docker `mongodb` 服务 + **`docker-compose.115.yml` override**
- **Replica set**: `rs0`，`115` 为 `priority: 0`, `votes: 0`

## 配置结构（override 方案）

| 场景 | 命令 | 配置文件 |
|------|------|----------|
| 新机器 / 本地开发（单机） | `docker compose up -d mongodb` | `mongodb/mongod.conf` |
| 115 灾备 & 未来主库 | `docker compose -f docker-compose.yml -f docker-compose.115.yml up -d mongodb` | `mongodb/mongod-replica.conf` + `keyfile` |

**同一服务名 `mongodb`、同一容器 `quant-mongodb`、同一数据卷 `mongodb7_*`**。扶正时无需换服务或迁卷，只需 `rs.reconfig` + 改 `MONGO_URI`。

115 override 额外收紧资源：容器 **1.5GB**、WiredTiger cache **0.5GB**、**1 CPU**（见 `mongod-replica.conf`）。

`180` 主库由 [`setup-mongodb-replica-primary.sh`](../infra/scripts/setup-mongodb-replica-primary.sh) 配置 systemd `/etc/mongod.conf`。

## 应用连接（灾备期）

写库仍指向 Primary：

```bash
MONGO_URI=mongodb://admin:***@180.184.28.170:27017/?authSource=admin
```

## 部署步骤

### 1. Primary（180）

```bash
MONGO_USER=admin MONGO_PASSWORD='***' \
PRIMARY_HOST=180.184.28.170 \
./setup-mongodb-replica-primary.sh
```

### 2. keyFile → 115

```bash
scp root@180.184.28.170:/etc/mongodb-keyfile \
  ~/trading/quant-infrastructure/infra/mongodb/keyfile
chmod 400 ~/trading/quant-infrastructure/infra/mongodb/keyfile
```

### 3. Secondary（115）

```bash
cd ~/trading/quant-infrastructure/infra/scripts
MONGO_USER=admin MONGO_PASSWORD='***' \
./setup-mongodb-replica-secondary.sh
```

或手动：

```bash
cd ~/trading/quant-infrastructure/infra
docker compose -f docker-compose.yml -f docker-compose.115.yml up -d mongodb
```

### 4. 验证

```bash
mongosh -u admin -p '***' --authenticationDatabase admin --eval 'rs.status()'
```

## 扶正（20 天后切主）

1. 确认 lag ≈ 0  
2. 在 180 上调整 priority 并 `rs.stepDown()`  
3. 应用 `MONGO_URI` 改为 `115.190.172.95` 或 `quant-mongodb`  
4. `rs.remove("180.184.28.170:27017")`  
5. 视负载调高 `docker-compose.115.yml` 的 `mem_limit` / `mongod-replica.conf` 的 `cacheSizeGB`

## 回滚

- 未加 Secondary：去掉 180 的 replication/keyFile，重启 mongod  
- 已加 Secondary：`rs.remove("115.190.172.95:27017")`，`compose down mongodb`

## 版本说明

115 可用 7.0 Secondary 同步 6.0 Primary；**禁止**在 6.0 Primary 仍在时让 115 自动升主。全量升级 180→7.0 后再考虑 HA。
