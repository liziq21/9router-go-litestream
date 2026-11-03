# ==========================================
# 阶段 1: 构建固定源码版本的轻量 Litestream 二进制文件 (Multi-stage build)
# 基于 Litestream v0.5.17，应用本仓库维护的 S3 DeleteObject fallback 和
# 并行恢复索引扫描补丁。源码 commit 固定，不依赖浮动的 main/latest。
# ==========================================
FROM golang:1.27-alpine@sha256:d200d2dd76b03a99b52651fd1325aff7dcd35422c35c01bac56571b0507f3deb AS litestream_bin

WORKDIR /src
ADD https://github.com/benbjohnson/litestream/archive/ccd326c175b583b5e82893a6078f06dcef5fba3f.tar.gz /tmp/litestream.tar.gz
COPY patches/litestream-delete-fallback.patch /tmp/litestream-delete-fallback.patch
COPY patches/litestream-restore-parallel.patch /tmp/litestream-restore-parallel.patch
RUN apk add --no-cache patch \
    && tar -xzf /tmp/litestream.tar.gz --strip-components=1 -C /src \
    && patch -d /src -p1 < /tmp/litestream-delete-fallback.patch \
    && patch -d /src -p1 < /tmp/litestream-restore-parallel.patch \
    && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.Version=v0.5.17-custom" \
        -o /usr/local/bin/litestream ./cmd/litestream

# ==========================================
# 阶段 2: 目标镜像包装
# 9router-go 1.9.15，digest 对应当前多架构 manifest。
# 更新基础镜像时请同步更新 tag 与 digest。
# ==========================================
FROM luqmenul/9router-go:1.9.15@sha256:6f3a591c58bab070aa1e4f0d65d856d0b46715c763409d58fe212359d1387973
USER root

# Keep 9router-go's database in the exact path monitored by Litestream.
ENV DATA_DIR=/data \
    DB_PATH=/data/db/data.sqlite \
    LITESTREAM_DB_PATH=/data/db/data.sqlite \
    LITESTREAM_EXPECTED_DATA_DIR=/data \
    LITESTREAM_EXPECTED_DB_PATH=/data/db/data.sqlite \
    APP_DEFAULT_COMMAND=9router-go

# 安装 ca-certificates（确保向 Cloudflare R2 进行 HTTPS 通信正常）
RUN if command -v apk > /dev/null 2>&1; then \
        apk add --no-cache ca-certificates; \
    elif command -v apt-get > /dev/null 2>&1; then \
        apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*; \
    fi

# 从构建阶段复制 litestream 可执行文件
COPY --from=litestream_bin /usr/local/bin/litestream /usr/local/bin/litestream

# 复制 Litestream v0.5 配置文件
COPY litestream.yml /etc/litestream.yml

# 复制启动脚本
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 保证数据库目录存在
RUN mkdir -p /data/db

# 暴露端口（9router-go 默认使用 20130）
EXPOSE 20130

# 使用自定义脚本作为入口点，包装原有的 CMD 命令
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["9router-go"]
