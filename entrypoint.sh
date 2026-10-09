#!/bin/sh
set -e

DB_PATH="/data/db/data.sqlite"
DB_DIR="/data/db"

mkdir -p "$DB_DIR"

if [ -n "$REPLICA_URL" ]; then
    echo "[Litestream] Remote backup enabled."
    
    # Litestream v0.5 推荐模式：
    # 配置文件方式启动 replicate，配合 -config /etc/litestream.yml 与 -exec "$@"
    # litestream replicate 内部会根据配置文件的 restore-if-db-not-exists: true 自动恢复数据库，并接管进程生命周期
    exec litestream replicate -config /etc/litestream.yml -exec "$@"
else
    echo "[Warning] REPLICA_URL is not set. Running 9router-go without Litestream replication."
    exec "$@"
fi
