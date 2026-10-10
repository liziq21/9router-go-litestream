# AGENTS.md

## 项目概览

本项目将固定版本的 `9router-go` 基础镜像与 Litestream 集成，用于把 `/data/db/data.sqlite` 实时复制到 S3 兼容的对象存储。项目主要由 Dockerfile、POSIX Shell 启动脚本和 Shell 行为测试组成，没有应用源代码或包管理器配置。

## 目录与关键文件

- `Dockerfile`：多阶段 Docker 构建文件。Litestream 和 `9router-go` 的版本及多架构 manifest digest 均需保持固定。
- `entrypoint.sh`：容器入口。没有设置 `REPLICA_URL` 时直接运行应用；设置后通过 Litestream `replicate -exec` 启动应用。
- `litestream.yml`：Litestream v0.5 配置，数据库路径固定为 `/data/db/data.sqlite`。
- `tests/entrypoint_test.sh`：不依赖真实镜像和对象存储的入口脚本行为测试。
- `tests/config_test.sh`：检查应用数据库目录与 Litestream 监控路径保持一致。
- `.github/workflows/docker-publish.yml`：Shell 语法检查、ShellCheck、入口测试和 Docker 构建，以及 GHCR 发布流程。
- `README.md`：用户配置、运行和故障恢复说明。

## 修改约定

- `entrypoint.sh` 必须保持 POSIX `/bin/sh` 兼容；不要引入 Bash 专有语法。
- 启用复制时，应用数据库必须固定为 `/data/db/data.sqlite`，并与 `litestream.yml` 保持一致；不要允许平台环境变量造成静默路径分叉。
- 修改入口脚本时必须保留命令参数边界，包括空格、单引号和其他特殊字符；变量应适当引用。
- 不要把凭据、访问密钥或真实对象存储 URL 写入源码、测试、文档或提交记录。使用占位符。
- 修改 Litestream 或基础镜像版本时，同时更新 tag 和 digest，并在变更说明中注明原因；不要改用未固定的 `latest`。
- `Dockerfile`（大写 D）是当前 CI 使用的规范构建文件。除非任务明确要求，不要恢复或并行维护已删除的旧版小写 `dockerfile`。
- 不要修改与当前任务无关的现有工作区变更，尤其是 `.github/workflows/docker-publish.yml`、`README.md` 和 `__agent__/` 中的内容。

## 本地验证

提交前至少运行：

```sh
sh -n entrypoint.sh tests/entrypoint_test.sh tests/config_test.sh
sh tests/entrypoint_test.sh
sh tests/config_test.sh
```

如果本机安装了 ShellCheck，再运行：

```sh
shellcheck entrypoint.sh tests/entrypoint_test.sh tests/config_test.sh
```

验证镜像构建时使用：

```sh
docker buildx build --platform linux/amd64 --file ./Dockerfile --tag 9router-go-litestream:ci --load .
```

CI 还会在 Alpine 容器中运行入口测试，并在合并或发布流程中执行多架构构建。涉及 Dockerfile、入口脚本或 Litestream 配置的改动，应尽可能完成对应的 Docker 构建验证。

## 提交前检查

1. 用 `git diff` 检查只包含预期修改。
2. 确认测试和 ShellCheck 均通过；若因本地缺少 Docker、ShellCheck 或网络导致未执行，应在交付说明中明确指出。
3. 检查文档中的环境变量、端口和镜像路径与实际配置一致。
