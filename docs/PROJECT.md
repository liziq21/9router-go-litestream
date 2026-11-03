# 项目定位

## 当前定位

本项目是一个面向 SQLite 应用的 Litestream 容器包装方案，当前提供两个经过验证的 9Router 应用 profile，以及一个仓库内 generic SQLite 示例：

- `9router-go`：Go 版本 9Router，默认端口 `20130`；
- `9router`：原版 Node.js 版本 9Router，默认端口 `20128`。
- generic SQLite 示例：Python 示例应用，默认端口 `8080`，用于验证显式 generic 契约，不作为已发布的黑盒镜像。

两个 profile 共用 POSIX `/bin/sh` 入口、Litestream 配置、对象存储凭据约定和 SQLite 恢复流程。应用镜像仍在构建阶段固定，运行时环境变量负责配置复制，而不是动态替换应用。

## 为什么这样定位

Litestream 官方已经支持通过 `replicate -exec` 在同一容器中管理应用，但不同应用仍然有自己的：

- 启动命令；
- 数据库路径和环境变量；
- 运行用户；
- 端口；
- 文件权限和迁移行为。

因此本项目采用“共享 wrapper + 应用 profile”，而不是声称一个镜像可以无条件适配所有 SQLite 应用。Phase 2 选择仓库内 generic 示例镜像作为最小可验证方案，不立即发布独立 wrapper 镜像；这样可以复用备份逻辑，同时让每个 profile 的数据库路径、启动命令和用户模型保持可验证。

generic profile 的应用命令通过 Docker `CMD` 提供，复制启用时必须显式设置 `LITESTREAM_DB_PATH`。应用数据目录、运行用户、组和端口仍需由 profile 明确声明，wrapper 不自动发现 SQLite 文件，也不负责应用专属 schema migration。

## 数据库兼容范围

原版 `9router` 和 `9router-go` 都使用 `$DATA_DIR/db/data.sqlite`。本项目的两个容器 profile 统一设置为：

```text
DATA_DIR=/data
DB_PATH=/data/db/data.sqlite
LITESTREAM_DB_PATH=/data/db/data.sqlite
```

`9router-go` 官方说明其数据库结构与原版 9Router 兼容，可以在停止写入进程后切换运行时并复用数据库。兼容性仍以具体应用版本和 schema 为准；升级前应保留完整 SQLite 数据目录备份。

generic 示例的路径为 `/var/lib/generic-sqlite/data.sqlite`，但该路径只在 Compose/测试中显式传入 `LITESTREAM_DB_PATH`；generic Dockerfile 不把它作为 wrapper 的隐式默认值。

## 配置原则

### 可复现构建

Litestream、应用基础镜像及多架构 manifest digest 均固定。更新版本时必须同时修改 tag、digest 和变更说明，不使用 `latest` 作为构建输入。

### 显式数据库路径

9Router profile 在启用复制时校验 `DATA_DIR`、`DB_PATH` 和 `LITESTREAM_DB_PATH`。如果平台覆盖了应用路径，容器会失败，而不会静默复制错误的 SQLite 文件。generic profile 在启用复制时只接受显式的 `LITESTREAM_DB_PATH`，不会根据目录或文件名猜测数据库。

### 安全传参

入口脚本将 Docker positional arguments 安全转换为 Litestream 的 `-exec` shell command string，保留空格、单引号和特殊字符的参数边界。

### 凭据不入仓库

副本 URL 和凭据只通过环境变量或平台 Secret 注入。文档、测试和提交记录只使用占位符。

## 非目标

当前版本不承诺：

- 运行时自动识别任意应用的 SQLite 文件；
- 仅通过环境变量替换 Docker 基础镜像；
- 自动修复任意应用的数据库迁移或 schema 不兼容；
- 多个应用进程同时写入同一个 SQLite 数据库；
- 将网络文件系统作为 SQLite 数据目录。

两个固定的 9Router profile 默认以 `LITESTREAM_MODE=required` 运行，缺少 replica
配置时拒绝启动。这是有意的 fail-closed 部署边界：容器本地文件系统不被视为可靠的
数据库持久化介质。用户若明确需要临时无复制运行，必须设置 `LITESTREAM_MODE=disabled`。

## 参考项目

- [Litestream Docker guide](https://litestream.io/guides/docker/)：官方同容器和 sidecar 模式；
- [litestream-docker-example](https://github.com/benbjohnson/litestream-docker-example)：官方 `-exec` 示例；
- [fly-apps/litestream-base](https://github.com/fly-apps/litestream-base)：把 Litestream 注入现有镜像的 base image 思路；
- [sqlite-litestream](https://github.com/fabiocicerchia/sqlite-litestream)：独立的 SQLite + Litestream 发行镜像。

本项目复用这些项目验证过的运行模式，但保留 9Router 特有的 profile 和数据库路径校验。
