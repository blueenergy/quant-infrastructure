# Quant Infrastructure

量化交易系统的基础设施与应用栈，分为两个对等子目录独立管理：

| 目录 | 职责 | 文档 |
|---|---|---|
| [`infra/`](./infra/README.md) | 基础设施栈（MongoDB / Redis / Hermes / Prometheus / Grafana / Portainer） | [infra/README.md](./infra/README.md) |
| [`apps/`](./apps/README.md) | 业务应用栈（API / Analyzer / 前端等），GitOps-lite Push-style CD | [apps/README.md](./apps/README.md) |

> [`k8s/`](./k8s/) 目录为 Kubernetes/K3s 清单（⚠️ 草稿，尚未真正启用）。

## 快速入口

```bash
# 启动基础设施（MongoDB、Redis 等）
cd infra
docker compose up -d

# 部署业务应用
cd apps
./deploy.sh
```

详细说明请分别查阅各子目录的 `README.md`。
