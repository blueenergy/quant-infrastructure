# MongoDB 配置：两套环境不要混用

仓库里 Mongo 有 **两种部署意图**，对应不同配置文件和 Compose override。

| 场景 | 机器 | 拓扑 | 配置文件 | Compose 启动 |
|------|------|------|----------|----------------|
| **WSL 主库 + Mac 灾备** | Windows WSL2 上的开发/写库机 | 复制集 `rs0`（PRIMARY + SECONDARY） | `mongod.conf` + 宿主机 `keyfile` 文件 | `docker compose up -d mongodb`（默认 `docker-compose.yml`） |
| **本机 Linux 等单机开发** | 无 Mac 复制、不做灾备同步 | **standalone**，仅 `authorization` | `mongod-standalone.conf` | `docker compose -f docker-compose.yml -f docker-compose.standalone.yml up -d mongodb` |
| **115 等灾备 Secondary** | 专用灾备机 | Secondary | `mongod-replica.conf` | `docker compose -f docker-compose.yml -f docker-compose.115.yml up -d mongodb` |

WSL + Mac 复制集操作细节见 monorepo 内 `llm-wiki/projects/devops/mongodb-replica-wsl-mac-secondary.md`。

## WSL：默认 `mongod.conf`（复制集 PRIMARY）

- `security.keyFile` + `replication.replSetName: rs0`
- 必须把 **文件**（不是目录）放到 `infra/mongodb/keyfile`，权限 `chmod 400`、`chown 999:999`（或 `docker run ... mongo:7.0 chown 999:999 /k`）
- 若挂载源不存在，Docker 可能创建 **空目录** `keyfile/`，mongod 会报 `permissions on /etc/mongodb-keyfile are too open` 并反复重启
- 业务连接：`directConnection=true`（见 wiki）

```bash
cd quant-infrastructure/infra
# 确认 keyfile 是文件且权限正确后
docker compose up -d mongodb
```

## 本机 Linux：standalone override

- **不要**挂 `keyfile`，**不要**使用带 `replication` 的 conf
- 若之前误建了目录，先删掉：`sudo rm -rf mongodb/keyfile`（仅 standalone 环境；WSL 上应是文件，勿删真 key）

```bash
cd quant-infrastructure/infra
docker compose -f docker-compose.yml -f docker-compose.standalone.yml up -d mongodb
```

验证：

```bash
mongosh "mongodb://admin:<password>@127.0.0.1:27017/?authSource=admin" --eval 'db.hello()'
# standalone 期望：isWritablePrimary: true，且无 replSetConfig（或 setName 为空）
```

`MONGO_PASSWORD` 与业务 `.env` 里 `MONGO_URI` 密码一致（如 `apps/.env` 的 `DOCKER_MONGO_URI`）。

## 数据卷说明

两种模式默认共用 Compose 卷 `mongodb7_data`。若某卷曾在 **rs0** 下初始化，再切 standalone 有时需单独评估（多数开发机可直接沿用；起不来再考虑备份后换卷）。**不要在生产卷上随意 `rs.initiate` / 删 keyfile 试错的混用。**

## 文件一览

| 文件 | 用途 |
|------|------|
| `mongod.conf` | WSL PRIMARY：auth + keyFile + rs0 |
| `mongod-standalone.conf` | 本机单机：仅 auth |
| `mongod-replica.conf` | 115 Secondary |
| `mongod-replica-primary.conf` | 115 扶正后 Primary |
| `keyfile` | **gitignore**；仅复制集需要 |
