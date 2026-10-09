#!/bin/sh
set -e

DB_PATH="/data/db/data.sqlite"
DB_DIR="/data/db"

mkdir -p "$DB_DIR"

# 如果没有传入参数，则默认执行原镜像的主程序 9router-go
if [ $# -eq 0 ]; then
    APP_CMD="9router-go"
else
    APP_CMD="$@"
fi

if [ -n "$REPLICA_URL" ]; then
    echo "[Litestream] Remote backup enabled."
    
    # 启动 litestream 监控并在后台运行 9router-go
    exec litestream replicate -config /etc/litestream.yml -exec "$APP_CMD"
else
    echo "[Warning] REPLICA_URL is not set. Running without Litestream replication."
    exec $APP_CMD
fi
