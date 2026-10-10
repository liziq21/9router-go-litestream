#!/bin/sh
set -e

DB_DIR="/data/db"

mkdir -p "$DB_DIR"

# 如果没有传入参数，则默认执行原镜像的主程序 9router-go。
# 保留 positional parameters，避免参数中的空格或特殊字符被破坏。
if [ "$#" -eq 0 ]; then
    set -- 9router-go
fi

# Litestream 的 -exec 接收一个 shell command string，而不是参数数组。
# 将每个参数安全地转换为单引号包裹的 shell word，供 Litestream 再解析。
shell_quote() {
    QUOTED="'"
    VALUE=$1

    while [ -n "$VALUE" ]; do
        CHAR=${VALUE%"${VALUE#?}"}
        VALUE=${VALUE#?}
        if [ "$CHAR" = "'" ]; then
            QUOTED="${QUOTED}'\\''"
        else
            QUOTED="${QUOTED}${CHAR}"
        fi
    done

    QUOTED="${QUOTED}'"
}

if [ -n "${REPLICA_URL:-}" ]; then
    # Litestream is configured for a fixed path. Set matching application
    # defaults here as a second line of defense against a platform override.
    DATA_DIR=${DATA_DIR:-/data}
    DB_PATH=${DB_PATH:-/data/db/data.sqlite}
    export DATA_DIR DB_PATH
    if [ "$DATA_DIR" != "/data" ] || [ "$DB_PATH" != "/data/db/data.sqlite" ]; then
        echo "[Error] DATA_DIR and DB_PATH must point to /data and /data/db/data.sqlite when replication is enabled." >&2
        exit 1
    fi

    echo "[Litestream] Remote backup enabled."

    APP_CMD=""
    for ARG do
        shell_quote "$ARG"
        if [ -n "$APP_CMD" ]; then
            APP_CMD="${APP_CMD} "
        fi
        APP_CMD="${APP_CMD}${QUOTED}"
    done

    # Litestream 负责接管子进程生命周期并处理优雅停机同步。
    exec litestream replicate -config /etc/litestream.yml -exec "$APP_CMD"
else
    echo "[Warning] REPLICA_URL is not set. Running without Litestream replication."
    exec "$@"
fi
