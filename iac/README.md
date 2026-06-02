# Byte V Forge IaC

此目录承载 Kubernetes 安装变量和 Helm chart。集群变量统一写到 Helm values。

## 目录

```text
iac/
  helm/byte-v-forge/          # 主 Helm chart
    values.yaml              # 默认变量，非生产密钥仅作占位
    values.local.example.yaml
  helm/traefik-values.yaml    # 官方 Traefik chart values
```

## 变量分层

- `configEnv`：非敏感运行参数，渲染为 ConfigMap。
- `secrets.stringData`：敏感参数，渲染为 Secret。
- `cloudflareEmail`：Cloudflare Email Routing 配置，渲染为 mailbox 读取的 proto JSON。
- `workloads`：每个服务的镜像、端口、探针、挂载和副本数。
- `dashboardRoutes`：WebUI、各 dashboard remote/API、n8n editor/webhook 和 mailbox webhook 的 Traefik `IngressRoute` 声明；Kubernetes 不再渲染标准 `Ingress`。
- `traefikStatus`：WebUI 读取 Traefik API 和内部状态路由的配置；服务发现/状态不再使用手写探测清单。
- `workloads.n8n-main`、`workloads.n8n-worker`、`workloads.n8n-webhook`、`workloads.n8n-postgres`、`workloads.n8n-redis`：n8n queue mode；独立 Postgres 持久化，独立 Redis 承载队列；workflow 编排使用 n8n editor。
- `workloads.workflow-runtime`：Workflow 原生 dashboard remote 和 `/api/workflow-runtime/*` API；对接 n8n public API，使用平台 Postgres 持久化 run/step 投影；n8n editor 不内嵌到业务前端。
- `workloads.platform-redis`：业务短生命周期 cache/relay/临时 secret、GoPay app runtime state，以及 mailbox 近期验证码热读和分布式抓取锁；与 `n8n-redis` 隔离，不作为领域状态真源。
- `workloads.platform-nats`：NATS JetStream 平台事件总线，承载跨服务持久事件、mailbox 公共邮件事件、mailbox 注册/OAuth、入站邮件 poll/fetch、SMS activation 轮询/取消、GPT OTP 投影消费和异步工作唤醒；`PLATFORM_EVENT_STREAM_*` 配置事件流名称、subject 和保留时间；业务数据库仍是状态真源。
- `workloads.cloudflare-tunnel`：Cloudflare Tunnel 连接器；公网 webhook 入口使用 `CLOUDFLARE_TUNNEL_TOKEN` 连接到 Cloudflare。

Kubernetes 部署中的代理地址使用集群可达的 Service、内网 IP 或 egress proxy。

## 使用

```bash
cp iac/helm/byte-v-forge/values.local.example.yaml iac/helm/byte-v-forge/values.local.yaml
```

编辑 `values.local.yaml` 后验证；n8n owner 由环境变量预置，默认登录邮箱为 `byte-v-forge@byte-v-forge.local`、密码为 `byte-v-forge`；进入 editor 后创建 public API key，再把 key 写入 `secrets.stringData.N8N_API_KEY`；Traefik 使用官方 OCI chart 和本目录的 values：

```bash
helm version --short
helm lint iac/helm/byte-v-forge -f iac/helm/byte-v-forge/values.local.yaml
helm template byte-v-forge iac/helm/byte-v-forge \
  --namespace byte-v-forge \
  -f iac/helm/byte-v-forge/values.local.yaml \
  >/tmp/byte-v-forge.yaml
helm template byte-v-forge-traefik oci://ghcr.io/traefik/helm/traefik \
  --version 40.2.0 \
  --namespace traefik \
  -f iac/helm/traefik-values.yaml \
  >/tmp/byte-v-forge-traefik.yaml
```

安装或升级：

```bash
helm upgrade --install byte-v-forge-traefik oci://ghcr.io/traefik/helm/traefik \
  --version 40.2.0 \
  --namespace traefik \
  --create-namespace \
  --rollback-on-failure \
  --wait=watcher \
  --wait-for-jobs \
  --timeout 10m \
  -f iac/helm/traefik-values.yaml

helm upgrade --install byte-v-forge iac/helm/byte-v-forge \
  --namespace byte-v-forge \
  --create-namespace \
  --rollback-on-failure \
  --wait=watcher \
  --wait-for-jobs \
  --timeout 10m \
  -f iac/helm/byte-v-forge/values.local.yaml
```

验证：

```bash
helm status byte-v-forge -n byte-v-forge
kubectl -n byte-v-forge get pods,svc,pvc
kubectl -n byte-v-forge get events --sort-by=.lastTimestamp
```
