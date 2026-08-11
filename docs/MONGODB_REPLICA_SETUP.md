# MongoDB Replica Set: 180 (Primary) + 115 (Secondary)

灾备拓扑（**6.0 Primary + 6.0 Secondary**，115 未来扶正为 Primary）：

| 节点 | 内网 IP | 运行方式 |
|------|---------|----------|
| **Primary（180）** | `192.168.200.59` | systemd MongoDB **6.0** |
| **Secondary（115）** | `192.168.201.16` | Docker `mongodb` + **`docker-compose.115.yml`**（`image: mongo:6.0`） |

- **Replica set**: `rs0`，115 为 `priority: 0`, `votes: 0`
- **复制集成员地址、应用 `MONGO_URI`、脚本默认值** 一律使用上表内网 IP（不用公网 `180.184.28.170` / `115.190.172.95`）

115 业务配置路径：`/home/deployuser/trading/quant-infrastructure/apps/env`（`common.env` 的 `MONGO_URI` 已指向 `192.168.200.59`）。

## 配置结构（override 方案）

| 场景 | 命令 | 配置文件 |
|------|------|----------|
| 新机器 / 本地开发（单机） | `docker compose up -d mongodb` | `mongodb/mongod.conf` |
| 115 灾备 & 未来主库 | `docker compose -f docker-compose.yml -f docker-compose.115.yml up -d mongodb` | `mongodb/mongod-replica.conf` + `keyfile` |

**同一服务名 `mongodb`、同一容器 `quant-mongodb`、同一数据卷 `mongodb7_*`**。扶正时无需换服务或迁卷，只需 `rs.reconfig` + 改 `MONGO_URI`。

115 override 额外收紧资源：容器 **1.5GB**、WiredTiger cache **0.5GB**、**1 CPU**（见 `mongod-replica.conf`）。

`180` 主库由 [`setup-mongodb-replica-primary.sh`](../infra/scripts/setup-mongodb-replica-primary.sh) 配置 systemd `/etc/mongod.conf`。

## 应用连接（灾备期）

写库仍指向 Primary 内网地址（与 `apps/env/common.env` 一致）：

```bash
MONGO_URI=mongodb://admin:***@192.168.200.59:27017/?authSource=admin
```

无需因搭建 Secondary 而修改；115 上的 `quant-mongodb` 容器仅作复制同步，不是业务写库目标。

## 部署步骤

### 1. Primary（180）

```bash
MONGO_USER=admin MONGO_PASSWORD='***' \
PRIMARY_HOST=192.168.200.59 \
./setup-mongodb-replica-primary.sh
```

`PRIMARY_HOST` 必须与 `apps/env/common.env` 里 `MONGO_URI` 的主机一致（不要用 `localhost`）。

### 2. keyFile → 115

```bash
scp root@192.168.200.59:/etc/mongodb-keyfile \
  /home/deployuser/trading/quant-infrastructure/infra/mongodb/keyfile
chmod 400 .../mongodb/keyfile
chown 999:999 .../mongodb/keyfile
```

### 3. Secondary（115）

```bash
cd /home/deployuser/trading/quant-infrastructure/infra/scripts
MONGO_USER=admin MONGO_PASSWORD='***' \
./setup-mongodb-replica-secondary.sh
```

或手动：

```bash
cd /home/deployuser/trading/quant-infrastructure/infra
docker compose -f docker-compose.yml -f docker-compose.115.yml up -d mongodb
```

### 4. 验证

```bash
mongosh -u admin -p '***' --authenticationDatabase admin --eval 'rs.status()'
```

期望成员地址为 `192.168.200.59:27017`（PRIMARY）与 `192.168.201.16:27017`（SECONDARY）。

115 上若仍看到 `syncSourceHost: '180.184.28.170:27017'`，说明 **Primary 成员在 `rs.conf` 里还是公网**，Secondary 只是如实显示同步源；执行 §5 的 `rs.reconfig` 后应变为 `192.168.200.59:27017`（通常几秒重连，无需全量重同步）。

### 5. 已用公网地址时，改为内网

若成员仍是公网 IP，在 Primary 上：

```javascript
cfg = rs.conf()
cfg.members.forEach(function (m) {
  if (m.host.startsWith("115.190.172.95")) m.host = "192.168.201.16:27017"
  if (m.host.startsWith("180.184.28.170")) m.host = "192.168.200.59:27017"
})
cfg.version++
rs.reconfig(cfg)
```

## 扶正（20 天后切主）

1. 确认 lag ≈ 0  
2. 在 180 上调整 priority 并 `rs.stepDown()`  
3. `apps/env/common.env` 的 `MONGO_URI` 改为 `192.168.201.16` 或 `mongodb://...@quant-mongodb:27017/...`（同机容器），重启业务  
4. `rs.remove("192.168.200.59:27017")`  
5. 视负载调高 `docker-compose.115.yml` 的 `mem_limit` / `mongod-replica.conf` 的 `cacheSizeGB`

## 回滚

- 未加 Secondary：去掉 180 的 replication/keyFile，重启 mongod  
- 已加 Secondary：`rs.remove("192.168.201.16:27017")`，`compose down mongodb`

## 版本说明

Primary 为 6.0 时 Secondary **必须同为 6.0**（7.0 会 wire version 不兼容）。升级与踩坑详见 quant-wiki：`projects/devops/mongodb-replica-secondary-180-115.md`。
