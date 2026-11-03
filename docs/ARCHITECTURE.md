# 运行架构

## 文件结构

```text
Dockerfile                 # 9router-go + Litestream profile
Dockerfile.9router         # 原版 9router + Litestream profile
Dockerfile.generic         # generic SQLite 示例 profile
entrypoint.sh              # 两个 profile 共用的 POSIX 入口
litestream.yml             # 单 SQLite 数据库的 Litestream 配置
patches/                    # 固定 Litestream 源码的兼容性和恢复性能补丁
README.md                  # 用户文档和快速开始
docs/
├── PROJECT.md             # 项目定位和设计边界
├── ARCHITECTURE.md        # 本文档
└── ROADMAP.md             # 演进路线和验收标准
tests/
├── entrypoint_test.sh     # 入口行为测试
├── config_test.sh          # Dockerfile/配置一致性测试
├── container_smoke_test.sh  # 已构建镜像的健康端点冒烟测试
├── container_replication_test.sh # 9Router file/S3 replica 恢复/停机同步测试
└── generic_container_test.sh # generic 示例的路径契约和恢复测试
```

## 构建层次

两个 Dockerfile 都使用多阶段构建：

1. 从固定 commit 的 Litestream v0.5.17 源码构建自定义二进制；
2. 从固定 digest 的应用镜像开始构建；
3. 复制共享配置和入口脚本；
4. 设置 profile 的数据目录、数据库路径、端口和应用用户。

当前 profile：

| 文件 | 应用镜像 | 默认端口 | 默认命令 | 运行用户 |
| --- | --- | ---: | --- | --- |
| `Dockerfile` | `luqmenul/9router-go:1.9.15` | `20130` | `9router-go` | 基础镜像默认用户（当前构建阶段为 root） |
| `Dockerfile.9router` | `decolua/9router:0.5.112` | `20128` | `node custom-server.js` | `node` |
| `Dockerfile.generic` | 固定 digest 的 `python:3.15-alpine` | `8080` | `python /opt/generic-sqlite/app.py` | `sqlite` |

`Dockerfile` 和 `Dockerfile.9router` 都把 `LITESTREAM_MODE` 的镜像默认值设为
`required`，并声明 `/data` 为 Docker volume。这样缺少远端副本时会 fail closed，避免
平台替换容器后才发现数据库只写在临时文件系统；托管平台仍必须配置持久磁盘或远端
Litestream replica。generic 示例保留共享入口的 `auto` 默认值，便于无复制的契约测试。

`Dockerfile.generic` 是仓库内可构建、可验证的 generic 示例，不是已经独立发布的黑盒镜像。它选择“仓库内 generic 示例镜像”方案，而不是 base image、runtime layer 或 sidecar：这样能在一个最小变更中验证入口的通用契约、SQLite 生命周期和权限模型；应用命令、端口、用户、数据目录仍由示例 Dockerfile 明确声明。稳定后再单独发布 wrapper 镜像，避免把未定义应用契约的镜像误当成通用产品。

### Generic 应用契约

generic wrapper 要求应用 profile 在构建期或运行时明确提供以下信息：

- 应用启动命令必须作为 Docker `CMD` positional arguments 传给入口；
- 启用复制时必须显式设置 `LITESTREAM_DB_PATH`；入口不会根据 `/data`、`DATA_DIR`、文件名或目录扫描猜测 SQLite 文件；
- 应用数据目录、SQLite 路径、`APP_USER`、`APP_GROUP` 和端口必须属于 profile 契约；
- `APP_COMMAND` 未解析的命令字符串不属于主要接口；
- generic wrapper 不负责应用专属 schema migration；
- 应用基础镜像、命令、用户和端口在 Dockerfile 中固定，运行时变量只配置复制和应用本身支持的选项。

示例 profile 的复制配置为：

```text
DATA_DIR=/var/lib/generic-sqlite
DB_PATH=/var/lib/generic-sqlite/data.sqlite
LITESTREAM_DB_PATH=/var/lib/generic-sqlite/data.sqlite
APP_USER=sqlite
APP_GROUP=sqlite
CMD ["python", "/opt/generic-sqlite/app.py"]
```

generic Dockerfile 不设置 `LITESTREAM_DB_PATH` 默认值，确保复制开启时缺少路径会立即失败。`LITESTREAM_MODE=disabled` 或 `auto` 且没有 replica 时仍可以直接运行应用。

## 入口流程

```text
容器启动
  │
  ├─ 读取 LITESTREAM_MODE、replica URL、数据库路径和配置路径
  ├─ 输出脱敏启动诊断（路径、权限、磁盘、身份和配置可读性）
  ├─ 创建数据库父目录
  ├─ 处理 Docker CMD positional arguments
  ├─ disabled              ──────> 直接启动应用
  ├─ auto + 无 replica URL  ──────> 警告后直接启动应用
  ├─ required + 无 URL     ──────> 失败
  └─ 有 replica URL
       ├─ 校验 profile 的路径契约
       ├─ 构造安全的 -exec command string
       └─ litestream replicate -config ... -exec ...
```

Litestream 负责应用子进程生命周期和优雅停机同步。启用 `APP_USER` 时，入口会在自身以 root 运行时准备数据目录权限，并通过 `su-exec` 或 `gosu` 让 Litestream 与应用使用同一用户。这样即使 `/data` 被 root 所有的持久化卷覆盖，原版 `9router` 仍然会写入 `/data/db/data.sqlite`。

## 环境变量优先级

### 复制模式

```text
共享入口的代码默认值为 `LITESTREAM_MODE=${LITESTREAM_MODE:-auto}`；两个 9Router
profile 在 Dockerfile 中覆盖为 `required`，generic profile 保持 `auto`。
LITESTREAM_REPLICA_URL > REPLICA_URL
LITESTREAM_CONFIG=${LITESTREAM_CONFIG:-/etc/litestream.yml}
generic replication: LITESTREAM_DB_PATH 必须显式设置
9Router profiles: LITESTREAM_DB_PATH > DB_PATH > DATA_DIR/db/data.sqlite
```

入口会把最终值导出为 `LITESTREAM_REPLICA_URL` 和 `LITESTREAM_DB_PATH`，供 Litestream 配置文件展开。`DB_PATH` 和 `DATA_DIR/db/data.sqlite` 仅保留给已有 9Router profile 的应用路径兼容，不能作为 generic 复制路径的隐式回退。

`litestream.yml` 默认使用 text 日志并包含源码位置。`LITESTREAM_LOG_LEVEL` 会作为
`litestream replicate` 的 `-log-level` 参数传递；默认级别为 `info`，排查恢复或对象存储
问题时可以设为 `debug` 或 `trace`。入口只记录 replica 的 scheme 和凭据是否已配置，
不会记录完整 replica URL、access key 或 secret key。

### 三种模式

| 模式 | 行为 |
| --- | --- |
| `auto` | 有 replica URL 才复制；没有时直接运行应用。共享入口的兼容默认值；不适合会替换实例的生产部署。 |
| `required` | 没有 replica URL 时直接失败，适合生产环境。 |
| `disabled` | 忽略 replica URL，直接运行应用，适合调试和临时操作。 |

## 数据库路径契约

两个 profile 的目标路径均为：

```text
/data/db/data.sqlite
```

启用复制时，profile 通过以下变量拒绝路径分叉：

```text
LITESTREAM_EXPECTED_DATA_DIR=/data
LITESTREAM_EXPECTED_DB_PATH=/data/db/data.sqlite
```

这些变量是 profile 的内部契约，不建议用户覆盖。未来 generic profile 可以不设置它们，改由用户明确提供 `LITESTREAM_DB_PATH`。

## 恢复和复制生命周期

`litestream.yml` 设置 `restore-if-db-not-exists: true`。Litestream 启动时：

1. 如果本地数据库存在，跳过恢复；
2. 如果本地数据库不存在且远端有副本，恢复数据库；
3. 如果本地数据库不存在且远端没有副本，创建新的复制源；
4. 启动应用并持续同步 WAL；
5. 收到停止信号时执行 shutdown sync。

配置将完整快照间隔设为 1h，缩短新实例恢复时需要重放的 L0/L1 增量窗口。
首次恢复仍会先于应用启动，因此部署平台的启动宽限时间必须覆盖远端恢复耗时。
自定义 Litestream 在 S3 批量 `DeleteObjects` 失败时会逐对象调用 `DeleteObject`，因此
`retention.enabled: true` 可以兼容只实现单对象删除的 provider。snapshot retention 会
保留最新完整 snapshot，并清理已被高层覆盖的旧 LTX；它不会把 Litestream 副本变成单一
可独立下载的对象。恢复计划中的各个非 snapshot level 也会并行 LIST，以降低空卷恢复的
串行等待。

## 参数边界

Litestream 的 `-exec` 接收一个 shell command string，而 Docker 入口收到的是参数数组。`shell_quote` 对每个参数进行 POSIX 单引号转义，再拼成一个字符串，避免参数中的空格和单引号被重新拆分。

不建议使用 `APP_COMMAND` 传入未解析的命令字符串。应用镜像应继续使用 Docker `CMD` 传递默认命令；没有 positional arguments 时，只有显式设置的单参数 `APP_DEFAULT_COMMAND` 兼容场景才会生效，否则入口直接失败。这避免 generic wrapper 静默选择应用命令。

## 部署模型

### 单容器

当前两个 profile 使用单容器模式，适合只允许一个 Web/worker 容器的托管平台。应用和 Litestream 共享同一个本地持久化卷。
两个 profile 默认要求 replica 已配置；如果平台会清除本地数据，应把远端副本视为恢复的
必要条件，而不是只依赖 `/data` 的本地 volume 声明。

### Sidecar

Docker 或 Kubernetes 能稳定共享本地卷时，也可以使用官方 Litestream 镜像作为 sidecar。sidecar 更符合“一容器一进程”，但不适用于所有平台，因此不是本仓库当前镜像的默认模式。

SQLite 数据目录应使用本地卷或本地块存储，避免 NFS、SMB 和其它不可靠的网络文件系统。
