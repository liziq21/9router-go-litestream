# 9Router / 9router-go with Litestream

这是一个面向 SQLite 应用的 Litestream 容器包装方案。当前提供两个固定版本的镜像 profile：

| 镜像构建文件 | 应用 | 端口 | 数据库路径 |
| --- | --- | ---: | --- |
| `Dockerfile` | `9router-go` | `20130` | `/data/db/data.sqlite` |
| `Dockerfile.9router` | 原版 `9router` | `20128` | `/data/db/data.sqlite` |
| `Dockerfile.generic` | generic SQLite 示例 | `8080` | 由 `LITESTREAM_DB_PATH` 显式提供 |

两个 profile 使用相同的 POSIX 入口和 Litestream 配置，把 SQLite WAL 实时复制到 S3 兼容对象存储，并在本地数据库不存在时尝试恢复。

项目定位、架构和演进计划见：

- [`docs/PROJECT.md`](docs/PROJECT.md)：项目定位、边界和设计原则；
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)：入口流程、变量优先级和数据路径；
- [`docs/ROADMAP.md`](docs/ROADMAP.md)：阶段目标与验收标准；
- [`docs/PHASE2_PROMPT.md`](docs/PHASE2_PROMPT.md)：下一阶段 generic wrapper 会话的可复制提示词。
- [`examples/generic-sqlite/compose.yml`](examples/generic-sqlite/compose.yml)：generic SQLite 示例的本地 Compose 配置。

## 为什么支持两个 9Router

原版 `9router` 和 `9router-go` 都使用 `$DATA_DIR/db/data.sqlite`。`9router-go` 官方项目说明其数据库 schema 与原版 9Router 兼容，因此可以在停止写入进程后切换运行时并继续使用已有 provider、connection、combo、API key 和 usage 数据。

兼容性仍取决于具体版本。升级应用或切换实现前，请停止应用并备份整个 SQLite 数据目录，包括 `data.sqlite`、`data.sqlite-wal`、`data.sqlite-shm` 和 Litestream 元数据目录。

## 获取或构建镜像

GHCR 发布镜像：

```text
ghcr.io/<YOUR_GITHUB_USERNAME>/9router-go-litestream:latest
ghcr.io/<YOUR_GITHUB_USERNAME>/9router-litestream:latest
```

构建 Go profile：

```sh
docker build -f Dockerfile -t 9router-go-litestream:local .
```

构建原版 profile：

```sh
docker build -f Dockerfile.9router -t 9router-litestream:local .
```

两个 Dockerfile 都固定了应用基础镜像和自定义 Litestream 构建的源码 commit/digest，不使用
`latest` 作为构建输入。自定义二进制基于 Litestream v0.5.17，额外包含：

- 当对象存储拒绝批量 `DeleteObjects` 但支持单对象 `DeleteObject` 时自动降级删除；
- 恢复计划的多个 level 并行执行远端 LIST，减少空卷恢复时的串行等待。

自定义构建补丁位于 [`patches/`](patches/)，三个 profile 的 Dockerfile 都从固定 digest 的
Go builder 编译同一个 Litestream 二进制。由于 builder 需要下载固定 commit 的源码，首次
构建需要网络；源码和补丁均不使用浮动分支。

## 环境变量

### Litestream

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `LITESTREAM_MODE` | 9Router profile 为 `required`；generic 为 `auto` | `auto`、`required` 或 `disabled`。 |
| `LITESTREAM_REPLICA_URL` | 未设置 | 副本地址，优先于旧变量 `REPLICA_URL`。 |
| `REPLICA_URL` | 未设置 | 旧版兼容变量，例如 `s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>`。 |
| `LITESTREAM_DB_PATH` | 9Router profile 在构建期设置；generic 无默认值 | Litestream 监控的 SQLite 文件。generic profile 启用复制时必须显式提供。 |
| `LITESTREAM_CONFIG` | `/etc/litestream.yml` | 自定义 Litestream 配置路径。 |
| `LITESTREAM_ACCESS_KEY_ID` | 未设置 | S3 access key。 |
| `LITESTREAM_SECRET_ACCESS_KEY` | 未设置 | S3 secret key。 |
| `AWS_ACCESS_KEY_ID` | 未设置 | Litestream 支持的标准 AWS 变量。 |
| `AWS_SECRET_ACCESS_KEY` | 未设置 | Litestream 支持的标准 AWS 变量。 |
| `LITESTREAM_LOG_LEVEL` | `info` | Litestream 日志级别；故障排查时可设为 `debug` 或 `trace`。 |
| `LITESTREAM_S3_DEBUG` | 未设置 | 可选的 AWS SDK S3 调试类别，例如 `retries,request,response`；不要在生产环境启用 `*-with-body`。 |

模式说明：

- `auto`：设置副本地址时启用复制，否则直接运行应用。共享入口/generic 示例的默认模式，兼容已有部署；
- `required`：没有副本地址时直接失败，适合生产环境；
- `disabled`：忽略副本地址，直接运行应用，适合调试或临时恢复。

两个 9Router profile 在镜像内默认使用 `required`，因此没有配置副本时会直接失败，
而不是启动一个会在容器替换后丢数据的实例。generic 示例仍由共享入口默认使用
`auto`；生产环境请显式使用 `required`。

两个 9Router profile 在启用复制时会校验 `DATA_DIR`、`DB_PATH` 和 `LITESTREAM_DB_PATH`。不要把它们覆盖到其它路径，否则容器会直接失败，避免产生未备份的数据库。

generic wrapper 不会根据 `DATA_DIR`、文件名或目录扫描猜测 SQLite 文件。启用复制时必须显式设置 `LITESTREAM_DB_PATH`；应用启动命令通过 Dockerfile 的 `CMD` positional arguments 提供，`APP_COMMAND` 未解析字符串不是主要接口。generic wrapper 也不负责应用专属 schema migration。

### 应用

原版 profile 的默认端口是 `20128`，Go profile 的默认端口是 `20130`。应用自身的其它变量继续由基础镜像提供，例如 `PORT`、`HOSTNAME`、`INITIAL_PASSWORD` 和 provider 配置变量。

## Docker CLI 示例

### 9router-go

```sh
docker run -d \
  --name 9router-go \
  --restart unless-stopped \
  -p 20130:20130 \
  -v 9router-go-data:/data \
  -e LITESTREAM_MODE=required \
  -e LITESTREAM_REPLICA_URL="s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>" \
  -e LITESTREAM_ACCESS_KEY_ID="<YOUR_ACCESS_KEY_ID>" \
  -e LITESTREAM_SECRET_ACCESS_KEY="<YOUR_SECRET_ACCESS_KEY>" \
  ghcr.io/<YOUR_GITHUB_USERNAME>/9router-go-litestream:latest
```

### 原版 9router

```sh
docker run -d \
  --name 9router \
  --restart unless-stopped \
  -p 20128:20128 \
  -v 9router-data:/data \
  -e INITIAL_PASSWORD="<YOUR_INITIAL_PASSWORD>" \
  -e LITESTREAM_MODE=required \
  -e LITESTREAM_REPLICA_URL="s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>" \
  -e LITESTREAM_ACCESS_KEY_ID="<YOUR_ACCESS_KEY_ID>" \
  -e LITESTREAM_SECRET_ACCESS_KEY="<YOUR_SECRET_ACCESS_KEY>" \
  ghcr.io/<YOUR_GITHUB_USERNAME>/9router-litestream:latest
```

如果只是本地运行而不需要复制，必须显式设置 `LITESTREAM_MODE=disabled`。不要在生产环境
通过 `auto` 忽略副本配置；这会让应用直接写入容器文件系统，平台替换实例后数据无法恢复。

### 没有永久磁盘的平台

平台不提供 `/data` 持久磁盘时，直接省略 `-v ...:/data`；Litestream 会把 `/data` 当作
临时工作目录，并在每次新实例启动时从 S3 兼容副本恢复。下面是无本地磁盘的 Go profile
示例：

```sh
docker run -d \
  --name 9router-go \
  --restart unless-stopped \
  -p 20130:20130 \
  -e LITESTREAM_MODE=required \
  -e LITESTREAM_REPLICA_URL="s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>" \
  -e LITESTREAM_ACCESS_KEY_ID="<YOUR_ACCESS_KEY_ID>" \
  -e LITESTREAM_SECRET_ACCESS_KEY="<YOUR_SECRET_ACCESS_KEY>" \
  ghcr.io/<YOUR_GITHUB_USERNAME>/9router-go-litestream:latest
```

不要在这类平台上添加只绑定到单个临时实例的匿名卷；它不会跨实例提供可靠恢复。

## Docker Compose 示例

```yaml
services:
  9router-go:
    image: ghcr.io/<YOUR_GITHUB_USERNAME>/9router-go-litestream:latest
    restart: unless-stopped
    ports:
      - "20130:20130"
    volumes:
      - 9router-go-data:/data
    environment:
      LITESTREAM_MODE: required
      LITESTREAM_REPLICA_URL: s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>
      LITESTREAM_ACCESS_KEY_ID: <YOUR_ACCESS_KEY_ID>
      LITESTREAM_SECRET_ACCESS_KEY: <YOUR_SECRET_ACCESS_KEY>

volumes:
  9router-go-data:
```

请将真实凭据放在 Compose secrets、平台 Secret 或 `.env` 管理系统中，不要提交到仓库。

## Generic SQLite 示例

仓库提供一个最小 Python/SQLite 应用，用来验证 generic wrapper 的数据库路径、用户权限、参数传递和恢复生命周期。它不是独立发布的通用黑盒镜像；应用命令、端口、用户和数据目录都在 `Dockerfile.generic` 中明确声明。

构建并启动示例：

```sh
docker buildx build --platform linux/amd64 --file ./Dockerfile.generic --tag generic-sqlite-litestream:local --load .
docker run --rm \
  -p 8080:8080 \
  -v generic-sqlite-data:/var/lib/generic-sqlite \
  -v generic-sqlite-replica:/replica \
  -e LITESTREAM_MODE=required \
  -e LITESTREAM_DB_PATH=/var/lib/generic-sqlite/data.sqlite \
  -e LITESTREAM_REPLICA_URL=file:///replica/backup \
  generic-sqlite-litestream:local
```

也可以运行 `examples/generic-sqlite/compose.yml`。`/health` 检查应用状态，`/touch` 会更新 SQLite 中的计数器：

```sh
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/touch
```

generic 示例刻意不在 Dockerfile 中设置 `LITESTREAM_DB_PATH`。如果设置 replica 但没有显式路径，入口会失败而不会静默备份错误文件。

## 恢复机制

`litestream.yml` 启用了 `restore-if-db-not-exists: true`：

1. 本地数据库存在时，Litestream 直接开始复制；
2. 本地数据库不存在但远端有备份时，先恢复再启动应用；
3. 本地数据库和远端备份都不存在时，作为首次安装启动并创建新副本；
4. 容器停止时执行最终同步。

启动日志应至少包含 `[Entrypoint] startup`、`[Litestream] Remote backup enabled.` 和
Litestream 的复制日志。如果日志只有 `9router-go Proxy ... starting` 而没有这些行，说明
当前部署没有运行本仓库包装镜像（常见原因是仍使用官方 `luqmenul/9router-go` 镜像，或
平台覆盖了镜像的 ENTRYPOINT）。请部署本仓库构建并发布的镜像，并确认平台没有覆盖
ENTRYPOINT/启动容器命令；否则 `LITESTREAM_*` 环境变量不会自动为官方应用镜像增加备份能力。

部署在会清除本地文件系统的托管平台时，必须同时满足以下条件：

1. 使用 `Dockerfile` 构建出的 `9router-go` 镜像（不是官方应用基础镜像）；
2. 设置 `LITESTREAM_MODE=required`、`LITESTREAM_REPLICA_URL`（或兼容的 `REPLICA_URL`）
   和对象存储凭据；
3. 副本地址使用独立的生产 prefix，并确认该 prefix 可读、可写；
4. 首次部署后检查 Litestream 已完成一次同步，再执行平台重启/替换测试。

本镜像不声明 Docker `VOLUME`，因此不要求平台提供永久磁盘。`/data` 只是 Litestream
恢复出来的本地工作副本；容器被替换后，`restore-if-db-not-exists: true` 会从远端副本
重新创建数据库。普通 Docker 部署仍可以自行把 `/data` 挂载到 named volume 以减少恢复
时间，但这只是可选优化，不能替代远端副本。

配置同时每小时生成一次完整快照，避免新实例在健康检查前重放过长的
L0/L1 增量历史。首次从远端恢复仍可能受数据库大小、对象存储吞吐和平台
启动宽限时间影响；没有永久磁盘的平台尤其要确保启动宽限时间覆盖最慢的一次恢复。

入口会在启动时输出不包含凭据和完整副本 URL 的诊断信息，包括最终数据库路径、
运行用户、目录读写状态、磁盘状态、配置文件可读性和凭据“已配置/未配置”状态。
启用复制时，应用要等 Litestream 完成恢复初始化后才会启动；如果日志停在
`attempting restore before replication`，说明应用尚未开始监听健康检查端口，应该优先
检查对象存储连接、凭据、权限和恢复耗时，而不是应用健康端点本身。

故障排查时可临时增加以下环境变量，然后重新部署：

```text
LITESTREAM_LOG_LEVEL=debug
LITESTREAM_S3_DEBUG=retries,request,response
```

`LITESTREAM_S3_DEBUG` 的请求/响应日志可能包含对象存储地址和错误响应内容；不要使用
`request-with-body` 或 `response-with-body`，因为它们可能暴露请求数据。凭据和完整副本
URL 不会由入口诊断日志打印。

当前默认启用了 Litestream 主动删除远端旧 LTX 文件。自定义 Litestream 已加入批量删除
失败后的逐对象删除 fallback，以兼容只支持单对象删除的 S3 服务。确认 provider 的
`DeleteObject` 可用后可以保持：

```yaml
retention:
  enabled: true
```

这会主动清理过期 snapshot 和已被高层 compact 覆盖的旧 LTX 文件，降低之后空卷恢复时
需要扫描的历史量。Litestream 仍会保留恢复所需的最新 snapshot；不会把整个副本压缩成一个
可独立下载的单文件。启用前请先在测试 prefix 验证 provider 的单对象删除权限。

## 本地工作目录与 SQLite 注意事项

- `/data` 是 Litestream 的本地 SQLite 工作目录，不要求持久化挂载；容器替换后由远端 replica 恢复；
- 如果平台提供本地磁盘，可以挂载 `/data` 作为恢复加速，但不要把它当作唯一备份；
- 不要将 SQLite 工作目录放在 NFS、SMB 或其它网络文件系统上；
- 数据库备份应包含 WAL、SHM 和 Litestream 元数据；
- 同一个 SQLite 数据库只运行一个主要写入实例；
- 原版 9router 和 9router-go 切换前先停止原进程，避免同时修改相同配置。

## 验证

本地 Shell 验证：

```sh
sh -n entrypoint.sh tests/entrypoint_test.sh tests/config_test.sh tests/container_smoke_test.sh tests/container_replication_test.sh
sh tests/entrypoint_test.sh
sh tests/config_test.sh
shellcheck entrypoint.sh tests/entrypoint_test.sh tests/config_test.sh tests/container_smoke_test.sh tests/container_replication_test.sh
```

镜像验证：

```sh
docker buildx build --platform linux/amd64 --file ./Dockerfile --tag 9router-go-litestream:ci --load .
docker buildx build --platform linux/amd64 --file ./Dockerfile.9router --tag 9router-litestream:ci --load .
sh tests/container_smoke_test.sh 9router-go-litestream:ci 20130
sh tests/container_smoke_test.sh 9router-litestream:ci 20128 /api/health
sh tests/container_replication_test.sh 9router-go-litestream:ci 20130 /health
sh tests/container_replication_test.sh 9router-litestream:ci 20128 /api/health
docker buildx build --platform linux/amd64 --file ./Dockerfile.generic --tag generic-sqlite-litestream:ci --load .
sh tests/generic_container_test.sh generic-sqlite-litestream:ci 8080
```

完整的 CI 还会执行 Alpine 容器中的入口测试、两个构建镜像的健康端点冒烟测试（Go profile 使用 `/health`，原版 profile 使用 `/api/health`）、两个 9Router profile 的 file replica 恢复测试、generic 示例的路径拒绝和恢复测试，以及 amd64/arm64 构建发布。真实 S3 兼容对象存储验收已配置为手动触发同一 workflow 执行，不参与普通 Pull Request，也不会因手动验收发布镜像。

真实 S3 验收需要在 GitHub `s3-test` Environment 中配置以下加密 Secrets：

```text
CI_REPLICA_URL
CI_LITESTREAM_ACCESS_KEY_ID
CI_LITESTREAM_SECRET_ACCESS_KEY
```

手动触发 workflow 后，测试会在提供的测试路径下使用本次 run id 创建两个独立 prefix：`ci/<run-id>/9router-go` 和 `ci/<run-id>/9router`。不要将生产数据库副本地址或生产凭据用于该 Environment。
