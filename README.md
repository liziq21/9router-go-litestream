# 9router-go with Litestream (SQLite Remote Backup)

基于 **Litestream 最新稳定版 (v0.5+)** 和 **Multi-stage build** 打包集成到 `luqmenul/9router-go:latest`，实现自动恢复与实时增量同步 `/data/db/data.sqlite` 至远端对象存储（支持 Cloudflare R2、Backblaze B2、AWS S3、MinIO 等任意 S3 兼容存储）。

---

## 1. 自动构建与镜像获取 (GitHub Packages / GHCR)

本项目已配置 GitHub Actions 自动多架构编译（支持 `linux/amd64` 和 `linux/arm64`）。

当你推送代码至 `main` 分支时，GitHub 将自动构建并发布至：
```text
ghcr.io/${OWNER}/9router:latest
```

在任何设备上，你都可以直接拉取：
```bash
docker pull ghcr.io/<YOUR_GITHUB_USERNAME>/9router:latest
```

*(如果需要在本地手动构建)*：
```bash
docker build -t 9router-go-litestream -f dockerfile .
```

---

## 2. 环境变量配置说明

| 变量名 | 说明 | 示例 |
| :--- | :--- | :--- |
| `REPLICA_URL` | 对象存储副本完整 URL（包含 endpoint 参数） | `s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>` |
| `LITESTREAM_ACCESS_KEY_ID` | API Token 的 Access Key ID / keyID | `your_access_key_id` |
| `LITESTREAM_SECRET_ACCESS_KEY` | API Token 的 Secret Key / applicationKey | `your_secret_access_key` |

> 也支持标准的 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`，Litestream 均会自动识别。

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
  ghcr.io/<YOUR_GITHUB_USERNAME>/9router:latest
```

### 方式二：Docker Compose (`docker-compose.yml`)

```yaml
version: "3.8"

services:
  9router-go:
    image: ghcr.io/<YOUR_GITHUB_USERNAME>/9router:latest
    restart: unless-stopped
    ports:
      - "20130:20130"
    environment:
      - REPLICA_URL=s3://<BUCKET_NAME>/db?endpoint=https://<ENDPOINT_HOST>
      - LITESTREAM_ACCESS_KEY_ID=<YOUR_ACCESS_KEY_ID>
      - LITESTREAM_SECRET_ACCESS_KEY=<YOUR_SECRET_ACCESS_KEY>
```

---

## 4. 工作机制特性（Litestream v0.5+）

- **自动故障恢复与初次启动 (`restore-if-db-not-exists: true`)**：容器启动时，若本地数据库文件不存在且远端对象存储中存在备份，会自动无缝拉取并还原；初次使用无备份时则正常直接初始化。
- **异常自愈 (`auto-recover: true`)**：检测到 LTX 交易异常或断点时自动恢复校验。
- **分层压缩 LTX 架构**：显著提升读写性能并大幅减少 S3 请求 API 调用频次与账单费用。
- **优雅停机数据落盘**：容器关闭时自动将待同步数据完整上传后退出。
