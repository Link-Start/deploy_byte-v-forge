# deploy

`deploy` 是 byte-v-forge 的唯一部署入口，负责把各子仓服务、前端模块、基础设施和运行配置声明式组合为可发布环境。

## 核心能力

- 维护 Docker Compose、Helm chart、values、环境示例和部署脚本。
- 组合 WebUI shell、业务远程模块、service catalog、路由、导航和运行时配置。
- 声明平台事件拓扑、runtime/provider adapter catalog、chart source 装载清单和多仓发布批次。
- 统一远程构建、镜像导入、Helm 渲染、部署升级和日志查看入口。

## 使用方式

本仓只维护部署组合与运行配置，不承载业务实现。源码编辑可在本机完成；镜像构建、部署验证和发布动作统一由远程宿主机环境执行。

## 入口

- Compose：`docker-compose.yml`
- Helm chart：`iac/helm/byte-v-forge/`
- 环境示例：`.env.example`
- 远程部署：`scripts/deploy-remote.sh`
- 配置检查：`scripts/validate-deploy-config.sh`
- 日志查看：`scripts/logs-remote.sh`

## 常用命令

```sh
scripts/validate-deploy-config.sh
scripts/deploy-remote.sh --validate-only webui gpt-service
scripts/deploy-remote.sh all
scripts/logs-remote.sh -f all
```
