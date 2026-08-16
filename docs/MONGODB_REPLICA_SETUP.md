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

## 扶正 Runbook（115 切为 Primary）

维护窗口执行。目标：写库从 **180**（`192.168.200.59`）切到 **115**（`192.168.201.16` / `quant-mongodb`），180 随后下线。

**前置条件**

- [ ] 115 已为 `SECONDARY`，`rs.printSecondaryReplicationInfo()` 显示 **lag ≈ 0**
- [ ] `rs.conf()` 成员均为内网：`192.168.200.59:27017`、`192.168.201.16:27017`
- [ ] 115 磁盘空闲 ≥ 10GB（`df -h /`）
- [ ] 已通知业务方进入维护窗口（写库切换约 1–5 分钟）

**涉及路径（115）**

| 路径 | 用途 |
|------|------|
| `/home/deployuser/trading/quant-infrastructure/apps/env/common.env` | 全业务共享 `MONGO_URI` |
| `/home/deployuser/trading/quant-infrastructure/apps/env/*.env` | 单服务覆盖（一般不必改，除非曾单独写死 180） |
| `/home/deployuser/trading/quant-infrastructure/infra/` | Mongo compose override |

115 上无宿主机 `mongosh` 时，用：`docker exec -it quant-mongodb mongosh -u admin -p '***' --authenticationDatabase admin`

### 回退窗口与风险（必读）

扶正**可以**回退到 180，但取决于切主进行到哪一步。**在 `rs.remove(180)` 之前**，复制集仍包含 180，一般可按下文「扶正失败 / 回滚」无损恢复拓扑；**之后**不能简单回退。

| 阶段 | 能否回退 180 当主库？ | 数据风险 |
|------|------------------------|----------|
| 尚未执行 `stepDown` | ✅ 可以 | 无；维持现状即可 |
| 已 `stepDown`，115 为 PRIMARY，**尚未** `rs.remove(180)` | ✅ 可以 | 若业务**尚未**改 `MONGO_URI`：无。若已在 115 写入：回退后 180 **没有**这些新数据 |
| 业务已在 115 产生新写入后再回 180 | ⚠️ 复制集可回，数据不一致 | 115 上的新文档不会自动出现在 180，需手工迁回或接受丢失 |
| 已 `rs.remove("192.168.200.59:27017")` | ❌ 不能简单回退 | 180 已非成员；只能 `rs.add` 180 并从 115 重新 initial sync，115 为唯一可信源 |

**为何 `rs.remove` 前能回退？**  
切主后 180 仍为 `SECONDARY`，与 115 同属 `rs0`。将 priority 调回 180 更高、115 上 `stepDown` 后，180 可重新升为 PRIMARY；再把 `MONGO_URI` 指回 `192.168.200.59` 即可。

**操作纪律（保证可回退）**

1. **先** 阶段 B（`reconfig` + `stepDown`），确认 115 为 PRIMARY  
2. **再** 阶段 C（改 `MONGO_URI`）；建议先只重启 `quant-api` 验证，再 `./deploy.sh` 全栈  
3. **观察** 至少 30 分钟（阶段 E 要求），确认 API、定时任务、写库正常  
4. **最后** `rs.remove(180)` 并停 180 的 `mongod`  

**勿**在业务刚切到 115、尚未观察稳定时 remove 180。  
**勿**在 115 已承接生产写入后，指望「一键回 180」且数据完整——除非确认维护窗口内**零写入**，或已做好差异数据迁移方案。

灾备期（115 仅为 `SECONDARY`，写库一直在 180）不存在「扶正失败」；下列 Runbook 仅用于**计划内切主**维护窗口。

---

### 阶段 A — 切主前检查（180 上，有 `mongosh`）

```javascript
rs.status().members.forEach(m => print(m.name, m.stateStr, m.health))
rs.printSecondaryReplicationInfo()
rs.conf().members.map(m => ({ host: m.host, priority: m.priority, votes: m.votes }))
```

期望：180 `PRIMARY`，115 `SECONDARY`，lag 0 秒。

---

### 阶段 B — 提升 115 为 Primary（180 上 mongosh）

115 当前为 `priority: 0, votes: 0`，**不会自动升主**，必须先 `reconfig` 再 `stepDown`。

```javascript
cfg = rs.conf()

// 按 host 匹配，勿假设 _id 顺序
cfg.members.forEach(function (m) {
  if (m.host.startsWith("192.168.201.16")) {
    m.priority = 2
    m.votes = 1
  }
  if (m.host.startsWith("192.168.200.59")) {
    m.priority = 1
    m.votes = 1
  }
})
cfg.version++
rs.reconfig(cfg)

// 等待 reconfig 传播（数秒）
rs.status()

// 让 180 退位，115 升主（60s 内若无其他 PRIMARY 候选则失败）
rs.stepDown(60)
```

等待 10–30 秒后确认：

```javascript
rs.status().members.forEach(m => print(m.name, m.stateStr))
```

期望：**115 → `PRIMARY`**，180 → `SECONDARY`。

若 115 未升主：检查 `votes` 是否为 1、`stepDown` 是否报错；勿进入阶段 C。

---

### 阶段 C — 应用改连 115（115 上）

**1. 修改 `common.env`**

灾备期（写 180）：

```bash
MONGO_URI=mongodb://admin:***@192.168.200.59:27017/?authSource=admin&maxPoolSize=20
```

扶正后（推荐同机容器名，走 Docker 网络）：

```bash
MONGO_URI=mongodb://admin:***@quant-mongodb:27017/?authSource=admin&maxPoolSize=20
```

或使用 115 内网 IP（宿主机 / `network_mode: host` 进程适用）：

```bash
MONGO_URI=mongodb://admin:***@192.168.201.16:27017/?authSource=admin&maxPoolSize=20
```

**2. 可选：启用 115 内存 profile**（若尚未设置）

```bash
COMPOSE_HOST_PROFILE=115
```

**3. 检查单服务 env 是否写死 180**

```bash
cd /home/deployuser/trading/quant-infrastructure/apps/env
grep -r '192.168.200.59\|180.184.28.170' . || true
```

有命中则改为 `quant-mongodb` 或 `192.168.201.16`。

**4. 重启业务栈**

```bash
cd /home/deployuser/trading/quant-infrastructure/apps
./deploy.sh
```

**5. 验证写库**

```bash
# 115 容器内
docker exec quant-mongodb mongosh --quiet -u admin -p '***' --authenticationDatabase admin \
  --eval 'db.adminCommand({ ismaster: 1 }).ismaster'   # 应为 true

# API 健康（按实际端口）
curl -sf http://127.0.0.1:3001/health || curl -sf http://127.0.0.1:3001/docs
```

在 `finance` 等库做一次只读查询或已知文档 spot-check，确认业务读到 115 数据。

---

### 阶段 D — 115 Mongo 升为生产资源配置（115 上）

切主成功且业务已改 URI 后再做（会 recreate 容器配置，**不删数据卷**）：

```bash
cd /home/deployuser/trading/quant-infrastructure/infra
docker compose -f docker-compose.yml -f docker-compose.115.yml -f docker-compose.115-primary.yml up -d mongodb
```

效果：`mem_limit` **3GB**，`mongod-replica-primary.conf`（`cacheSizeGB: 1.5`）。  
扶正后监控：`docker stats quant-mongodb`、`free -h`。

---

### 阶段 E — 下线 180 成员（180 仍在线时，在 **新 Primary / 115** 上 mongosh）

> **不可逆点**：`rs.remove(180)` 之后无法按「扶正失败 / 回滚」一键回到 180 主库。务必完成阶段 F 检查且观察足够时间后再执行。

确认 115 业务稳定 **至少 30 分钟**（建议数小时、含一个定时任务周期）后再移除 180：

```javascript
rs.status()   // 115 为 PRIMARY，180 为 SECONDARY
rs.remove("192.168.200.59:27017")
rs.status()   // 仅剩 115 单成员亦可工作（单节点 PRIMARY）
```

**180 主机收尾**（确认无需回退后）：

```bash
systemctl stop mongod
systemctl disable mongod   # 按需
```

备份任务、监控告警中的 Mongo 地址改为 115（`192.168.201.16` 或 `quant-mongodb`）。  
若存在 `MONGODB_BACKUP_MONGO_URI`、`SECONDARY_MONGO_URI` 等变量，同步更新。

---

### 阶段 F — 切主后检查清单

| 检查项 | 命令 / 期望 |
|--------|-------------|
| 复制集 | 115 `PRIMARY`，`rs.printSecondaryReplicationInfo()` 无 180 |
| 业务写库 | 新写入文档在 115 `finance` 等库可查 |
| 定时任务 | `quant-scheduler` / `quant-scorer` 日志无 Mongo 连接错误 |
| 内存 | `docker stats` 无 Mongo OOM；`dmesg \| grep -i oom` 无新记录 |
| 磁盘 | `df -h /` 余量充足 |

---

### 扶正失败 / 回滚（切主后发现问题，且 180 尚未 `rs.remove`）

适用：**阶段 B/C 异常**，或业务切到 115 后发现问题，但**尚未**执行阶段 E 的 `rs.remove`。

**若业务尚未在 115 写入**（仅改了 URI 或仅 stepDown）：按下列步骤回滚后，数据与扶正前一致。

**若已在 115 有生产写入**：复制集可回到 180 主库，但 115 上多出的文档**不会**自动同步到 180（180 在回滚瞬间的数据截止于切换前的 oplog）。需评估：接受丢失、或停机导出差异后再回滚。

在 **115（当前 PRIMARY）** 上：

```javascript
cfg = rs.conf()
cfg.members.forEach(function (m) {
  if (m.host.startsWith("192.168.200.59")) { m.priority = 2; m.votes = 1 }
  if (m.host.startsWith("192.168.201.16")) { m.priority = 0; m.votes = 1 }
})
cfg.version++
rs.reconfig(cfg)
rs.stepDown(120)   // 115 退位，180 应重新升为 PRIMARY
```

确认 `rs.status()`：180 → `PRIMARY`，115 → `SECONDARY`。

**应用回滚**：`common.env` 的 `MONGO_URI` 改回 `192.168.200.59`，`cd apps && ./deploy.sh`。

若已套用 `docker-compose.115-primary.yml`，可退回仅 `docker-compose.115.yml` 的 Secondary 资源配置。

**已 `rs.remove(180)` 时**：无法按上表回退。可选路径：以 115 继续修复；或将 180 作为新 Secondary `rs.add` 后从 115 全量同步（耗时长，且 115 为唯一数据源）。

---

### 115 扶正后内存预算（8GB 宿主机）

业务与 Mongo 同机时，须给**无 mem_limit 的容器**加上限，并压低 scorer/researcher 默认顶（原默认 4G/6G 与 Mongo 叠加易 OOM）。

| 组件 | 灾备 Secondary | 扶正 Primary |
|------|----------------|--------------|
| Mongo 容器 | 1.5GB / cache 0.5GB | **3GB / cache 1.5GB** |
| quant-api 等无上限服务 | — | **apps/docker-compose.115.yml** 加 cap |
| quant-scorer / researcher | 默认 4G/6G | **默认 2G/2G**（可 env 覆盖） |
| quant-factor-researcher | 默认 8G | **`FACTOR_BACKTEST_RUNTIME=external_k8s`** |

**apps**（`common.env` 设 `COMPOSE_HOST_PROFILE=115`，`deploy.sh` 自动加载 override）：

```bash
cd /home/deployuser/trading/quant-infrastructure/apps && ./deploy.sh
```

**infra Mongo Primary**（见阶段 D）。

日常监控：`free -h`、`docker stats`、扶正后关注 `dmesg | grep -i oom`。长期建议 115 扩至 **16GB** 或 Mongo 独立部署。

---

## 回滚（灾备期，未扶正）

- 未加 Secondary：去掉 180 的 replication/keyFile，重启 mongod  
- 已加 Secondary：`rs.remove("192.168.201.16:27017")`，`compose down mongodb`

## 版本说明

Primary 为 6.0 时 Secondary **必须同为 6.0**（7.0 会 wire version 不兼容）。升级与踩坑详见 llm-wiki：`projects/devops/mongodb-replica-secondary-180-115.md`。
