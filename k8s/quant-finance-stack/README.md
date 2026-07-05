# Quant Finance 应用在 K3s / Kubernetes 上的部署

> ⚠️ **DRAFT / 尚未真正启用** — 本 Kustomize 清单仍处于草稿阶段，未在生产环境实际部署。
> 目前生产使用 `infra/docker-compose.yml`（基础设施）+ `apps/docker-compose.yml`（应用栈）。
> 本目录仅供后续迁移到 K3s/Kubernetes 时参考，使用前需自行校验镜像名、密钥与挂载方式。

本目录将 `quantFinance/docker-compose.yml` 中的应用栈映射为 **Kustomize** 清单，便于在 **K3s**（或其它 Kubernetes）中用 `kubectl` / `kustomize` 管理 Deployment 与 Service。

> **与 Compose 的差异**  
> - Compose 里的 `build:` 在集群中需改为**已推送到镜像仓库**的镜像；清单里用占位名，通过 `kustomization.yaml` 的 `images:` 替换。  
> - 宿主机 bind-mount（如把 `../quantAnalyzer/src` 挂进容器）在默认清单中**未**复刻；代码应打进镜像，或通过 PVC / Git-sync 等进阶方式挂载（需自行扩展 YAML）。  
> - MongoDB / Redis 若仍用本仓库 `quant-infrastructure/docker-compose.yml` 跑在集群外，把 `MONGO_URI` 指到节点 IP 或 LoadBalancer；若部署在集群内，可改为 `mongodb://mongo.quant-infra.svc.cluster.local:27017/` 等形式。

## 目录结构

```
quant-finance-stack/
├── README.md                 # 本说明
├── templates/
│   └── secret.env.example    # 密钥环境变量模板
└── base/
    ├── kustomization.yaml    # Kustomize 入口（镜像名、资源列表）
    ├── namespace.yaml
    ├── configmap.yaml        # 非敏感默认配置（时区、对内 URL 等）
    ├── configmap-web-nginx.yaml
    ├── quant-api.yaml
    ├── quant-strategy-manager.yaml
    ├── quant-assistant.yaml
    ├── quant-analyzer.yaml   # StatefulSet ×2，WORKER_ID = Pod 名
    ├── quant-data-engine.yaml
    ├── backtest-worker.yaml
    ├── quant-scorer.yaml
    ├── web.yaml
    └── ingress-web.yaml      # 可选；默认在 kustomization 中注释掉
```

## K3s 快速步骤

1. **构建并推送镜像**（示例标签 `latest`，生产请用版本号）  
   与各仓库 `Dockerfile` / `docker-compose.yml` 中的 `build.context` 一致，在 CI 或本地构建后推送到你的仓库（如 `ghcr.io/<org>/quant-api`）。

2. **改镜像地址**  
   编辑 `base/kustomization.yaml` 中 `images:` 的 `newName` / `newTag`，或执行：
   ```bash
   cd quant-infrastructure/k8s/quant-finance-stack/base
   kustomize edit set image quant-api=myregistry/quant-api:v20260403
   # 对其余 image 逐项设置，或直接用 vim 编辑 kustomization.yaml
   ```

3. **创建命名空间与 Secret**（必须先有 `quant-secrets`，否则 Pod 会因缺 Secret 无法创建）
   ```bash
   kubectl apply -f namespace.yaml
   cp ../templates/secret.env.example secret.env
   # 编辑 secret.env
   kubectl create secret generic quant-secrets -n quant-finance --from-env-file=secret.env
   ```
   若使用私有仓库拉镜像：
   ```bash
   kubectl create secret docker-registry regcred -n quant-finance \
     --docker-server=ghcr.io --docker-username=... --docker-password=...
   ```
   并在各 `Deployment`/`StatefulSet` 的 `spec.template.spec` 下增加：
   `imagePullSecrets: [{ name: regcred }]`（可用 Kustomize patch 统一加）。

4. **部署**
   ```bash
   kubectl apply -k .
   ```
   或在仓库根目录：
   ```bash
   kubectl apply -k quant-infrastructure/k8s/quant-finance-stack/base
   ```

5. **对外暴露前端（可选）**  
   - 临时：`kubectl port-forward -n quant-finance svc/quant-web 8080:80`  
   - 长期：在 `base/kustomization.yaml` 中取消注释 `ingress-web.yaml`，将其中 `host: quant-dashboard.local` 改成你的域名，并配置 DNS 指向 K3s 入口 IP；TLS 可用 cert-manager 或 Traefik 证书。

6. **策略管理 API 等其它端口**  
   当前仅 `quant-web` 与可选 Ingress 暴露 HTTP。若需从集群外访问 `quant-api:3001`、`quant-strategy-manager:5000` 等，请自行增加 `Service` `type: LoadBalancer` / `NodePort` 或单独 `Ingress`（注意鉴权与 TLS）。

## 服务名与 Compose 对应关系

| Compose `service`        | Kubernetes Service 名           | 端口 |
|---------------------------|-----------------------------------|------|
| quant-api                 | `quant-api`                       | 3001 |
| quant-strategy-manager    | `quant-strategy-manager`          | 5000 |
| quant-assistant           | `quant-assistant`                 | 8002 |
| quant-analyzer-1/2        | `quant-analyzer`（StatefulSet）   | 无对外 HTTP |
| quant-data-engine         | （未建 Service，仅内部 Pod）       | 可按需加 |
| backtest-worker           | （同上）                           |      |
| quant-scorer              | （同上）                           |      |
| web                       | `quant-web`                       | 80   |

集群内 DNS 示例：`http://quant-api.quant-finance.svc.cluster.local:3001`（与 `configmap.yaml` 中 `INTERNAL_API_BASE` 一致）。

## Nginx 配置

`configmap-web-nginx.yaml` 内为精简版配置：仅 HTTP、`/api` 反代到 `quant-api`。若需与仓库根目录 `quantFinance/nginx.conf` 完全一致（缓存、SSL、证书文件等），可：

```bash
kubectl create configmap quant-web-nginx -n quant-finance --from-file=nginx.conf=/path/to/quantFinance/nginx.conf -o yaml --dry-run=client | kubectl apply -f -
```
注意将其中 `upstream` 的 `server` 改为 `quant-api.quant-finance.svc.cluster.local:3001`。

## 监控（Compose `profiles: monitoring`）

本 `base` 未包含 Prometheus/Grafana；可在集群中使用 [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) 或把 `quantFinance/docker-compose.yml` 中的监控容器改写为 Deployment + PVC 后放到 `overlays/monitoring/`。

## 校验清单

- [ ] 所有业务镜像已构建并 `kustomization.yaml` 中 `images` 已指向正确仓库  
- [ ] `quant-secrets` 已创建且包含至少：`MONGO_URI`、`MONGO_DB`、`JWT_SECRET_KEY`；按需：`TUSHARE_TOKEN`、`QWEN_API_KEY` 等  
- [ ] MongoDB 可从 Pod 内访问（网络策略、防火墙、URI 正确）  
- [ ] 私有镜像已配置 `imagePullSecrets`（如适用）
