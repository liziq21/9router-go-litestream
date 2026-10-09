# 1. 引入现成的 litestream 提取二进制文件
FROM litestream/litestream:0.3.13 AS litestream_bin

# 2. 你的主体依然是 9router 官方镜像
FROM ghcr.io/decolua/9router:latest
USER root

# 3. 复制二进制文件
COPY --from=litestream_bin /usr/local/bin/litestream /usr/local/bin/litestream

# 4. 直接使用极简命令包裹（核心：依靠内部默认机制）
ENTRYPOINT ["/bin/sh", "-c", "mkdir -p /app/data/db && litestream restore -if-db-not-exists -if-replica-exists /app/data/db/data.sqlite && exec litestream replicate -exec 'node dist/index.js' /app/data/db/data.sqlite $REPLICA_URL"]
