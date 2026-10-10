# 9router-go with Litestream (SQLite Remote Backup)

基于固定版本的 **Litestream v0.5.17** 和 **Multi-stage build** 打包集成到 `luqmenul/9router-go:1.9.10`，实现自动恢复与实时增量同步 `/data/db/data.sqlite` 至远端对象存储（支持 Cloudflare R2、Backblaze B2、AWS S3、MinIO 等任意 S3 兼容存储）。Dockerfile 同时固定了多架构镜像 digest，避免上游 `latest` 变更导致构建结果漂移。

---

## 1. 自动构建与镜像获取 (GitHub Packages / GHCR)

本项目已配置 GitHub Actions 自动多架构编译（支持 `linux/amd64` 和 `linux/arm64`）。提交 Pull Request 时会先执行入口脚本测试、ShellCheck 和 amd64 Docker 构建验证；只有合并后的分支或版本标签才会推送镜像。

当你推送代码至 `main` 分支时，GitHub 将自动构建并发布至（工作流使用 `${{ github.repository }}` 作为镜像名）：
```text
ghcr.io/<YOUR_GITHUB_USERNAME>/9router-go-litestream:latest
```

当前仓库的镜像地址为：
```text
ghcr.io/liziq21/9router-go-litestream:latest
```

在任何设备上，你都可以直接拉取：
```bash
docker pull ghcr.io/<YOUR_GITHUB_USERNAME>/9router-go-litestream:latest
```

*(如果需要在本地手动构建)*：
```bash
docker build -t 9router-go-litestream -f Dockerfile .
```

Dependabot 会每天检查 Docker 基础镜像的版本和 digest，每周检查 GitHub Actions 依赖，并通过 Pull Request 提交更新。更新 PR 必须通过入口脚本测试、ShellCheck 和 Docker 构建验证后再人工合并。

---

## 2. 环境变量配置说明

| 变量名 | 说明 | 示例 |
| :--- | :--- | :--- |
| `REPLICA_URL` | 对象存储副本完整 URL（包含 endpoint 参数） | `s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>` |
| `LITESTREAM_ACCESS_KEY_ID` | API Token 的 Access Key ID / keyID | `your_access_key_id` |
| `LITESTREAM_SECRET_ACCESS_KEY` | API Token 的 Secret Key / applicationKey | `your_secret_access_key` |

> 镜像已内置 `DATA_DIR=/data` 和 `DB_PATH=/data/db/data.sqlite`，确保 9router-go 使用的数据库与 Litestream 监控的 `/data/db/data.sqlite` 完全一致。不要在 Koyeb 或其它平台覆盖这两个变量。
>
> 也支持标准的 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`，Litestream 均会自动识别。
>
> 启用复制时，入口脚本也会检查并固定这两个路径；如果平台覆盖成其它路径，容器会直接报错，而不会静默运行一个未备份的数据库。

### Koyeb 部署注意事项

Koyeb 的本地实例存储是临时的，实例重新调度或重建后不能依赖本地文件保留数据库。因此在 Koyeb 上必须使用 `REPLICA_URL` 和对象存储凭据，并且不要覆盖 `DATA_DIR` / `DB_PATH`。

首次使用修复后的镜像时，如果日志显示 `no backup found, starting fresh`，请重新导入配置；导入后确认后续日志不再持续出现 `timeout waiting for db initialization`。之后实例重启应显示已从副本恢复（或不再显示 `no backup found`）。此前版本如果把数据库写到了未被 Litestream 监控的路径，旧配置不会出现在对象存储中，需要重新导入。

---

## 3. 运行容器示例

### 方式一：Docker CLI 直接运行

```bash
docker run -d \
  --name 9router-go \
  -p 20130:20130 \
  -e REPLICA_URL="s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>" \
  -e LITESTREAM_ACCESS_KEY_ID="<YOUR_ACCESS_KEY_ID>" \
  -e LITESTREAM_SECRET_ACCESS_KEY="<YOUR_SECRET_ACCESS_KEY>" \
  ghcr.io/<YOUR_GITHUB_USERNAME>/9router-go-litestream:latest
```

### 方式二：Docker Compose (`docker-compose.yml`)

```yaml
version: "3.8"

services:
  9router-go:
    image: ghcr.io/<YOUR_GITHUB_USERNAME>/9router-go-litestream:latest
    restart: unless-stopped
    ports:
      - "20130:20130"
    environment:
      - REPLICA_URL=s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>
      - LITESTREAM_ACCESS_KEY_ID=<YOUR_ACCESS_KEY_ID>
      - LITESTREAM_SECRET_ACCESS_KEY=<YOUR_SECRET_ACCESS_KEY>
```

---

## 4. 工作机制特性（Litestream v0.5.17）

- **自动故障恢复与初次启动 (`restore-if-db-not-exists: true`)**：容器启动时，若本地数据库文件不存在且远端对象存储中存在备份，会自动无缝拉取并还原；初次使用无备份时则正常直接初始化。
- **异常自愈 (`auto-recover: true`)**：检测到 LTX 交易异常或断点时自动重置本地跟踪状态并重新同步。该模式优先保证服务持续运行，但可能丢失异常发生前的部分时间点恢复能力；如果时间点恢复优先，请在部署前将 `litestream.yml` 中的 `auto-recover` 改为 `false`。
- **分层压缩 LTX 架构**：显著提升读写性能并大幅减少 S3 请求 API 调用频次与账单费用。
- **优雅停机数据落盘**：容器关闭时自动将待同步数据完整上传后退出。
- **参数安全传递**：容器传入的应用命令参数会保留空格和特殊字符，不会被入口脚本重新拆分。
