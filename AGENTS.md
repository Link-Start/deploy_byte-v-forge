# AGENTS.md

本仓是 `deploy` 部署仓。

- 本仓承载 Docker Compose、Helm chart、部署 values、环境示例和部署脚本。
- 本仓负责最终前端模块组合、打包配置和部署期装载；可以感知 `webui`、基础设施仓和业务仓的前端模块边界。
- 前后端组合都必须声明式维护，例如模块 manifest、service catalog、capabilities、routes/nav/actions、provider runtime config 和部署 values；不要把组合逻辑写回 `webui` 或基础设施仓。
- `webui` 只作为 shell/uikit/module-kit 来源；业务仓和基础设施仓发布自己的可注册前端模块，本仓在构建部署阶段组合。
- 不提交真实 secret、真实账号、真实 token、真实代理凭据或真实会话材料。
- `.env.example` 和 values 示例只放占位值或虚构值。
- Linter 检查必须达到 0 error / 0 warning；禁止通过修改或放宽 linter 配置、降低规则级别、删除规则、添加 ignore/disable/nolint/ts-ignore/eslint-disable/biome-ignore/prettier-ignore 等方式绕过问题，只能按 linter 规则修复源码、类型、格式或依赖边界。
- Helm 变更需要通过 `helm lint` 和 `helm template` 做非测试类检查。
- 脚本变更需要通过 `bash -n` 做语法检查。
- 本仓不维护 CI/CD 配置，不新增 `.github/`、GitLab CI、Jenkins、Dependabot 等自动化流水线配置。
- Mac 本机不作为业务镜像构建环境；真实镜像构建、导入和部署动作使用远程宿主机。
