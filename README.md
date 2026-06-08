# Deploy

本仓承载 byte-v-forge 的部署入口、IaC、环境示例和部署辅助脚本。

## 目录

- `docker-compose.yml`：本地或远程 Docker Compose 部署入口。
- `.env.example`：部署变量示例。
- `iac/helm/byte-v-forge/`：Kubernetes Helm chart。
- `iac/helm/traefik-values.yaml`：官方 Traefik Helm chart 的本项目默认 values。
- `scripts/deploy-remote.sh`：远程构建、导入镜像和 Helm 升级脚本。
- `scripts/validate-deploy-config.sh`：非构建类部署配置检查入口，执行脚本语法检查与 Helm lint/template。
- `scripts/logs-remote.sh`：远程 Kubernetes 日志查看脚本。
- `release-manifest.example.json`：多仓发布批次清单示例。
- `chart-source-manifest.json`：部署期装载的 SQL migration 与 n8n workflow owner 源清单。
- `event-topology.json`：平台事件 channel、outbox、consumer 和迁移债清单。
- `runtime-adapter-catalog.json`：provider/runtime adapter SPI、注册点和遗留 inline registry 清单。
- `docs/release-governance.md`：发布批次、契约迁移和 chart source 装载规则。

WebUI、n8n editor、n8n webhook 和 mailbox webhook 的外部 HTTP 入口统一走 Traefik `IngressRoute`，不再渲染 Kubernetes `Ingress`，也不再保留 ingress-nginx 双入口。Docker Compose 暴露 `WEBUI_PORT`、`WEBHOOK_PORT` 和本机 n8n editor 端口 `N8N_EDITOR_PORT`；Kubernetes 默认由 Traefik `web` NodePort 30080 发布 dashboard，由 `webhook` NodePort 30082 发布 webhook 路由。WebUI 的服务状态从 Traefik API 读取，不再维护手写服务探测清单。需要公网 mailbox webhook 时启用 `workloads.cloudflare-tunnel`，把 Cloudflare Tunnel token 写入 `secrets.stringData.CLOUDFLARE_TUNNEL_TOKEN`，并只在 Cloudflare Tunnel 上放行 `/webhooks/email/` 前缀。
Cloudflare 邮箱域名通过 Helm `cloudflareEmail` 声明 zones，并由 mailbox 使用 `MAILBOX_CLOUDFLARE_API_TOKEN` 从 Cloudflare Email Routing catch-all 规则与 MX DNS 配置推导；不在 values 里手填邮箱 domains。该 token 限制到目标 zone，并授予 `Zone Read`、`DNS Read` 和 `Email Routing Rules Read` 即可。

## Helm 渲染

```sh
scripts/validate-deploy-config.sh
```

## 远程部署

```sh
scripts/deploy-remote.sh all
```

部署脚本默认只在远程宿主机构建镜像，启用 BuildKit，并给镜像写入 `org.opencontainers.image.*` 标签。默认并发构建数为 2，可按远程宿主机资源调整：

```sh
BUILD_PARALLELISM=3 scripts/deploy-remote.sh webui gpt-service
scripts/deploy-remote.sh --build-pull --tag deploy-20260531 webui
scripts/deploy-remote.sh --validate-only webui gpt-service
```

`--validate-only` 会同步源码、生成 dashboard module registry、写入本次 overlay，并只执行远程 Helm lint/template，不构建镜像、不导入镜像、不升级 release。常规部署会把本次 tag、构建时间和源码 revision 写入所选 workload 的 pod annotations，避免未选 workload 因全局 annotation 变化被动滚动。

部署脚本默认从本仓父目录读取 sibling 目标仓源码，例如 `common-lib/`、`gpt/`、`gopay-app/`、`mailbox/`、`sms/`、`wa-app/`、`browser-automation/`、`proxy-runtime/`、`workflow-runtime/` 和 `webui/`，并同步到远程构建目录。可通过 `SOURCE_ROOT` 指定源码父目录。未设置 `RELEASE_MANIFEST` 时，脚本会拒绝同步有未提交改动的已选源码仓；只允许临时调试场景显式设置 `ALLOW_DIRTY_SOURCE=1`。
需要冻结多仓发布批次时，复制 `release-manifest.example.json`，把 `repos[].revision` 改为本次发布允许的 git SHA/ref，然后执行：

```sh
RELEASE_MANIFEST=/path/to/release-manifest.json scripts/deploy-remote.sh --validate-only webui gpt-service
RELEASE_MANIFEST=/path/to/release-manifest.json scripts/deploy-remote.sh all
```

设置 `RELEASE_MANIFEST` 后，部署前会校验所选源码仓的当前 `HEAD` 与清单 revision 一致，并默认拒绝脏仓。`chart-source-manifest.json` 是 Helm chart 装载源的声明式清单，SQL migration 和 n8n workflow 仍由业务仓持有，部署仓只在同步前暂存到 chart files。
Dashboard 模块、事件拓扑和 runtime/provider adapter 也由部署仓声明式校验：`dashboard-catalog.json` 中的 MF 模块必须指向服务拥有方的 `webui/src/dashboard/manifest.tsx`，独立 UI 使用 `externalApps` 声明入口；`event-topology.json` 必须区分 JetStream 可回放事件和 NATS core hotstream，`runtime-adapter-catalog.json` 必须声明每个 provider/runtime adapter 的 SPI、注册点和遗留迁移债。
n8n 直接以 queue mode 部署，使用独立 `n8n-postgres` 与 `n8n-redis`；owner 账号通过 n8n 官方环境变量预置，默认登录邮箱为 `byte-v-forge@byte-v-forge.local`、密码为 `byte-v-forge`；n8n public API key 需要在 n8n UI 创建后写入 `N8N_API_KEY`。workflow JSON/catalog 保留在拥有该能力的业务仓，例如 `gpt/workflows/n8n/`、`gpt-private/workflows/n8n/`、`gopay-app/workflows/n8n/` 和 `wa-app/workflows/n8n/`；Codex 等公开 GPT workflow 可留在 `gpt`，支付等私有 GPT workflow 进入 `gpt-private`，GoPay account workflow 进入 `gopay-app`；`gpt-service` Dockerfile 固定构建 core runtime，不再嵌入 `gpt-private` overlay、GoPay payment sidecar 或私有迁移；GPT checkout `PaymentService` 由独立 `gpt-checkout` workload 从 `gpt-private/gopay` 构建并通过 `GPT_PAYMENT_INTERNAL_ADDR` 注入；私有 GPT workflow/action 元数据留在 `gpt-private`，通过公开 GPT/gopay-app HTTP 或 gRPC 边界集成；`workflow-runtime` 提供平台原生 dashboard 远程模块和状态 API，使用平台 Postgres 持久化 run/step 投影，n8n 节点通过 `WORKFLOW_RUNTIME_API_BASE_URL` 与 `WORKFLOW_RUNTIME_STEP_UPDATE_TOKEN` 上报状态；n8n editor 仅作为管理员编排入口。
业务短生命周期缓存、relay、GoPay app runtime state、mailbox 近期邮件/验证码 secret、分布式抓取锁，以及 workflow 入参敏感临时值使用独立 `platform-redis`，通过 `PLATFORM_REDIS_URL` 注入业务服务；SMS 的 PostgreSQL、Redis 和 NATS 均使用 `SMS_PG_DSN`、`SMS_REDIS_URL`、`SMS_NATS_URL`、`SMS_EVENT_STREAM_NAME` 独立配置，留空时使用服务内可选降级。`GPT_RUNTIME_SECRET_TTL_SECONDS` 控制 GPT 临时 secret 保留时间，`GOPAY_STATE_TTL_SECONDS` 控制 GoPay app runtime state 保留时间，`MAILBOX_RECENT_EMAIL_CACHE_TTL_SECONDS` 控制 mailbox 近期邮件缓存和验证码 secret 保留时间，`MAILBOX_INBOX_LOCK_TTL_SECONDS` 控制 mailbox 跨副本抓取锁租约。跨服务持久事件、GPT OTP 投影消费和异步工作唤醒使用 `platform-nats` NATS JetStream；mailbox 使用 `MAILBOX_NATS_URL` 和 `MAILBOX_EVENT_STREAM_NAME` 独立配置 NATS，GPT 等平台业务继续通过 `PLATFORM_NATS_URL` 注入；`PLATFORM_EVENT_STREAM_*` 控制平台事件流名称、subject 和保留时间。业务数据库仍是状态真源。`n8n-redis` 只归 n8n queue mode 使用，不作为业务缓存、业务事件流或业务状态源。
部署脚本默认先安装/升级 Traefik release `byte-v-forge-traefik`，再升级 `byte-v-forge` Helm release；可通过脚本参数或环境变量覆盖。
`browser-automation` 使用独立 runtime base 镜像承载 Camoufox、Playwright、GeoIP 和浏览器资源；常规业务部署只重建服务二进制层。远程镜像导入默认先尝试宿主机本地 registry 分层导入，失败后才回退到 qemu guest agent tar 导入。registry 端口可通过 `DEPLOY_REGISTRY_PUSH_ADDR` 和 `DEPLOY_REGISTRY_PULL_ADDR` 覆盖。

## 日志

```sh
scripts/logs-remote.sh gpt-service
scripts/logs-remote.sh -f all
```
