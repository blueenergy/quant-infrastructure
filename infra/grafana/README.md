# Grafana（草稿，未真正启用）

> ⚠️ **DRAFT** — Grafana 与 Prometheus 同属 `docker-compose.yml` 的 `monitoring`
> profile，默认 `docker compose up -d` 不会启动。以下目录目前仅为占位骨架，
> 尚无实际面板 / 数据源配置，待后续完善后再正式启用。

- `dashboards/` — Grafana 面板 provisioning（当前为空）
- `datasources/` — 数据源 provisioning，指向 Prometheus（当前为空）

启用监控（含 Grafana）：

```bash
cd infra
docker compose --profile monitoring up -d
```
