# Deploy

本仓承载 byte-v-forge 的部署入口、IaC、环境示例和部署辅助脚本。

## 目录

- `docker-compose.yml`：本地或远程 Docker Compose 部署入口。
- `.env.example`：部署变量示例。
- `iac/helm/byte-v-forge/`：Kubernetes Helm chart。
- `iac/helm/traefik-values.yaml`：官方 Traefik Helm chart 的本项目默认 values。
- `scripts/deploy-remote.sh`：远程构建、导入镜像和 Helm 升级脚本。
- `scripts/logs-remote.sh`：远程 Kubernetes 日志查看脚本。

WebUI、n8n editor、n8n webhook、mailbox webhook 和 GoPay OTP webhook 的外部 HTTP 入口统一走 Traefik `IngressRoute`，不再渲染 Kubernetes `Ingress`，也不再保留 ingress-nginx 双入口。Docker Compose 暴露 `WEBUI_PORT`、`WEBHOOK_PORT` 和本机 n8n editor 端口 `N8N_EDITOR_PORT`；Kubernetes 默认由 Traefik `web` NodePort 30080 发布 dashboard，由 `webhook` NodePort 30082 发布 webhook 路由。WebUI 的服务状态从 Traefik API 读取，不再维护手写服务探测清单。需要公网 mailbox webhook 时启用 `workloads.cloudflare-tunnel`，把 Cloudflare Tunnel token 写入 `secrets.stringData.CLOUDFLARE_TUNNEL_TOKEN`，并只在 Cloudflare Tunnel 上放行 `/webhooks/email/` 前缀。
Cloudflare 邮箱域名通过 Helm `cloudflareEmail` 声明 zones，并由 mailbox 使用 `MAILBOX_CLOUDFLARE_API_TOKEN` 从 Cloudflare Email Routing catch-all 规则与 MX DNS 配置推导；不在 values 里手填邮箱 domains。该 token 限制到目标 zone，并授予 `Zone Read`、`DNS Read` 和 `Email Routing Rules Read` 即可。

## Helm 渲染

```sh
helm lint iac/helm/byte-v-forge
helm template byte-v-forge iac/helm/byte-v-forge --namespace byte-v-forge >/tmp/byte-v-forge.yaml
helm template byte-v-forge-traefik oci://ghcr.io/traefik/helm/traefik \
  --version 40.2.0 --namespace traefik -f iac/helm/traefik-values.yaml >/tmp/byte-v-forge-traefik.yaml
```

## 远程部署

```sh
scripts/deploy-remote.sh all
```

部署脚本默认从本仓父目录读取 sibling 目标仓源码，例如 `common-lib/`、`gpt/`、`mailbox/`、`sms/`、`browser-automation/`、`proxy-runtime/`、`workflow-runtime/` 和 `webui/`，并同步到远程构建目录。可通过 `SOURCE_ROOT` 指定源码父目录。
n8n 直接以 queue mode 部署，使用独立 `n8n-postgres` 与 `n8n-redis`；owner 账号通过 n8n 官方环境变量预置，默认登录邮箱为 `byte-v-forge@byte-v-forge.local`、密码为 `byte-v-forge`；n8n public API key 需要在 n8n UI 创建后写入 `N8N_API_KEY`。workflow JSON/catalog 保留在业务仓，例如 `mailbox/workflows/n8n/` 和 `gpt/workflows/n8n/`；`workflow-runtime` 提供平台原生 dashboard 远程模块和状态 API，n8n editor 仅作为管理员编排入口。
业务短生命周期缓存、relay、GoPay app runtime state、mailbox 近期验证码热读和分布式抓取锁，以及 workflow 入参敏感临时值使用独立 `platform-redis`，通过 `PLATFORM_REDIS_URL` 注入业务服务；`GPT_RUNTIME_SECRET_TTL_SECONDS` 控制 GPT 临时 secret 保留时间，`GOPAY_STATE_TTL_SECONDS` 控制 GoPay app runtime state 保留时间，`MAILBOX_RECENT_EMAIL_CACHE_TTL_SECONDS` 控制 mailbox 近期邮件缓存保留时间，`MAILBOX_INBOX_LOCK_TTL_SECONDS` 控制 mailbox 跨副本抓取锁租约。跨服务持久事件、mailbox 公共邮件事件、mailbox 注册/OAuth、入站邮件 poll/fetch、SMS activation 轮询/取消、GPT OTP 投影消费和异步工作唤醒使用 `platform-nats` NATS JetStream，通过 `PLATFORM_NATS_URL` 注入业务服务；`PLATFORM_EVENT_STREAM_*` 控制平台事件流名称、subject 和保留时间。业务数据库仍是状态真源。`n8n-redis` 只归 n8n queue mode 使用，不作为业务缓存、业务事件流或业务状态源。
部署脚本默认先安装/升级 Traefik release `byte-v-forge-traefik`，再升级 `byte-v-forge` Helm release；可通过脚本参数或环境变量覆盖。
`browser-automation` 使用独立 runtime base 镜像承载 Camoufox、Playwright、GeoIP 和浏览器资源；常规业务部署只重建服务二进制层。远程镜像导入默认先尝试宿主机本地 registry 分层导入，失败后才回退到 qemu guest agent tar 导入。registry 端口可通过 `DEPLOY_REGISTRY_PUSH_ADDR` 和 `DEPLOY_REGISTRY_PULL_ADDR` 覆盖。

## 日志

```sh
scripts/logs-remote.sh gpt-service
scripts/logs-remote.sh -f all
```
