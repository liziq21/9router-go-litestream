# ==========================================
# 阶段 1: 提取 Litestream 最新版二进制文件 (Multi-stage build)
# ==========================================
FROM litestream/litestream:latest AS litestream_bin

# ==========================================
# 阶段 2: 目标镜像包装
# ==========================================
FROM luqmenul/9router-go:latest
USER root

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
