# ==========================================
# 阶段 1: 提取固定版本的 Litestream 二进制文件 (Multi-stage build)
# Litestream 0.5.17，digest 对应 linux/amd64 + linux/arm64 manifest。
# 更新版本时请同步更新 tag 与 digest。
# ==========================================
FROM litestream/litestream:0.5.17@sha256:4b02b9859a6b6b4087d8b8944e15f7e984bd7957cba322bbeee38b0e27b9656a AS litestream_bin

# ==========================================
# 阶段 2: 目标镜像包装
# 9router-go 1.9.10，digest 对应当前多架构 manifest。
# 更新基础镜像时请同步更新 tag 与 digest。
# ==========================================
FROM luqmenul/9router-go:1.9.10@sha256:739fa24182fc1e1c5613c3ded92987a20428f5bddf5d1d765b31ab68886e9fcf
USER root

# Keep 9router-go's database in the exact path monitored by Litestream.
ENV DATA_DIR=/data \
    DB_PATH=/data/db/data.sqlite

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
