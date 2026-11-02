#!/bin/sh
set -e

MODE=${LITESTREAM_MODE:-auto}
REPLICA=${LITESTREAM_REPLICA_URL:-${REPLICA_URL:-}}
CONFIG=${LITESTREAM_CONFIG:-/etc/litestream.yml}
APP_DATA_DIR=${DATA_DIR:-/data}
APP_DB_PATH=${DB_PATH:-${APP_DATA_DIR}/db/data.sqlite}
DB_PATH_TO_REPLICATE=${LITESTREAM_DB_PATH:-$APP_DB_PATH}
EXPECTED_DATA_DIR=${LITESTREAM_EXPECTED_DATA_DIR:-}
EXPECTED_DB_PATH=${LITESTREAM_EXPECTED_DB_PATH:-}
APP_GROUP=${APP_GROUP:-${APP_USER:-}}

REPLICA_SCHEME=none
case "$REPLICA" in
    *:*)
        REPLICA_SCHEME=${REPLICA%%:*}
        ;;
    ?*)
        REPLICA_SCHEME=unknown
        ;;
esac

EFFECTIVE_LOG_LEVEL=${LITESTREAM_LOG_LEVEL:-${LOG_LEVEL:-info}}
ACCESS_KEY_STATE=missing
SECRET_KEY_STATE=missing
if [ -n "${LITESTREAM_ACCESS_KEY_ID:-}" ] || [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    ACCESS_KEY_STATE=configured
fi
if [ -n "${LITESTREAM_SECRET_ACCESS_KEY:-}" ] || [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    SECRET_KEY_STATE=configured
fi

log_message() {
    printf '%s\n' "[Entrypoint] $*" >&2
}

describe_path() {
    INSPECT_PATH=$1
    PATH_KIND='missing'
    if [ -f "$INSPECT_PATH" ]; then
        PATH_KIND='file'
    elif [ -d "$INSPECT_PATH" ]; then
        PATH_KIND='directory'
    fi

    if [ "$PATH_KIND" = missing ]; then
        log_message "path=$INSPECT_PATH kind=missing"
        return 0
    fi

    if [ -r "$INSPECT_PATH" ]; then
        PATH_READABLE=yes
    else
        PATH_READABLE=no
    fi
    if [ -w "$INSPECT_PATH" ]; then
        PATH_WRITABLE=yes
    else
        PATH_WRITABLE=no
    fi
    log_message "path=$INSPECT_PATH kind=$PATH_KIND readable=$PATH_READABLE writable=$PATH_WRITABLE"

    if command -v ls >/dev/null 2>&1; then
        if LS_DETAIL=$(ls -ld "$INSPECT_PATH" 2>&1); then
            log_message "path_detail=$LS_DETAIL"
        fi
    fi
}

log_startup_diagnostics() {
    CURRENT_UID=unknown
    CURRENT_GID=unknown
    if command -v id >/dev/null 2>&1; then
        CURRENT_UID=$(id -u 2>/dev/null || printf '%s' unknown)
        CURRENT_GID=$(id -g 2>/dev/null || printf '%s' unknown)
    fi

    log_message "startup mode=$MODE config=$CONFIG db_path=$DB_PATH_TO_REPLICATE app_db_path=$APP_DB_PATH replica_scheme=$REPLICA_SCHEME log_level=$EFFECTIVE_LOG_LEVEL"
    log_message "runtime uid=$CURRENT_UID gid=$CURRENT_GID app_user=${APP_USER:-root} app_group=${APP_GROUP:-} access_key=$ACCESS_KEY_STATE secret_key=$SECRET_KEY_STATE s3_debug=$([ -n "${LITESTREAM_S3_DEBUG:-}" ] && printf enabled || printf disabled)"
    describe_path "$APP_DATA_DIR"
    describe_path "$DB_DIR"
    describe_path "$DB_PATH_TO_REPLICATE"

    DISK_PATH=$DB_DIR
    if [ ! -d "$DISK_PATH" ]; then
        DISK_PATH=$APP_DATA_DIR
    fi
    if command -v df >/dev/null 2>&1; then
        if DISK_DETAIL=$(df -h "$DISK_PATH" 2>&1); then
            log_message "disk_path=$DISK_PATH disk=$DISK_DETAIL"
        else
            log_message "disk_check=failed path=$DISK_PATH detail=$DISK_DETAIL"
        fi
    fi

    if [ -r "$CONFIG" ]; then
        log_message "config_readable=yes"
    else
        log_message "config_readable=no path=$CONFIG"
    fi
}

case "$MODE" in
    auto|required|disabled)
        ;;
    *)
        echo "[Error] LITESTREAM_MODE must be auto, required, or disabled." >&2
        exit 1
        ;;
esac

case "$DB_PATH_TO_REPLICATE" in
    */*)
        DB_DIR=${DB_PATH_TO_REPLICATE%/*}
        [ -n "$DB_DIR" ] || DB_DIR=/
        ;;
    *)
        DB_DIR=.
        ;;
esac

exec_as_app() {
    if [ -n "${APP_USER:-}" ] && [ "$APP_USER" != "root" ]; then
        if command -v su-exec >/dev/null 2>&1; then
            exec su-exec "$APP_USER" "$@"
        elif command -v gosu >/dev/null 2>&1; then
            exec gosu "$APP_USER" "$@"
        else
            echo "[Error] APP_USER=$APP_USER requires su-exec or gosu." >&2
            exit 1
        fi
    fi

    exec "$@"
}

prepare_app_data() {
    [ -n "${APP_USER:-}" ] || return 0
    [ "$APP_USER" = "root" ] && return 0

    mkdir -p "$APP_DATA_DIR"
    if [ "$(id -u)" -eq 0 ]; then
        if ! command -v chown >/dev/null 2>&1; then
            echo "[Error] APP_USER=$APP_USER requires chown when the entrypoint runs as root." >&2
            exit 1
        fi
        chown -R "$APP_USER:${APP_GROUP:-$APP_USER}" "$APP_DATA_DIR"
    fi
}

# Docker CMD 以 positional arguments 提供应用命令。只有显式设置的单参数
# APP_DEFAULT_COMMAND 才可用于没有 CMD 的测试/兼容场景；generic profile 不
# 设置它，也不会依赖某个固定应用命令。
if [ "$#" -eq 0 ]; then
    if [ -n "${APP_DEFAULT_COMMAND:-}" ]; then
        set -- "$APP_DEFAULT_COMMAND"
    else
        echo "[Error] no application command was provided by Docker CMD." >&2
        exit 1
    fi
fi

if [ "$MODE" = "required" ] && [ -z "$REPLICA" ]; then
    echo "[Error] LITESTREAM_MODE=required needs LITESTREAM_REPLICA_URL or REPLICA_URL." >&2
    exit 1
fi

log_startup_diagnostics

if [ "$MODE" = "disabled" ]; then
    echo "[Litestream] Replication disabled."
    prepare_app_data
    exec_as_app "$@"
fi

if [ -z "$REPLICA" ]; then
    echo "[Warning] Replica URL is not set. Running without Litestream replication."
    prepare_app_data
    exec_as_app "$@"
fi

if [ -z "${LITESTREAM_DB_PATH:-}" ]; then
    echo "[Error] LITESTREAM_DB_PATH must be explicitly set when replication is enabled." >&2
    exit 1
fi

# Profile images can pin the application and Litestream to one known path. This
# prevents a platform override from silently putting the application's SQLite
# file outside Litestream's coverage. Generic images can leave these unset.
if [ -n "$EXPECTED_DATA_DIR" ] && [ "$APP_DATA_DIR" != "$EXPECTED_DATA_DIR" ]; then
    echo "[Error] DATA_DIR must be $EXPECTED_DATA_DIR when replication is enabled." >&2
    exit 1
fi
if [ -n "$EXPECTED_DB_PATH" ] && {
    [ "$APP_DB_PATH" != "$EXPECTED_DB_PATH" ] ||
    [ "$DB_PATH_TO_REPLICATE" != "$EXPECTED_DB_PATH" ]
}; then
    echo "[Error] DB_PATH and LITESTREAM_DB_PATH must be $EXPECTED_DB_PATH when replication is enabled." >&2
    exit 1
fi

mkdir -p "$DB_DIR"
prepare_app_data
log_message "prepared data directory and database parent directory"
describe_path "$APP_DATA_DIR"
describe_path "$DB_DIR"
describe_path "$DB_PATH_TO_REPLICATE"

export LITESTREAM_DB_PATH="$DB_PATH_TO_REPLICATE"
export LITESTREAM_REPLICA_URL="$REPLICA"

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

echo "[Litestream] Remote backup enabled."
log_message "starting Litestream; application will not start until restore initialization completes"

APP_CMD=""
for ARG do
    shell_quote "$ARG"
    if [ -n "$APP_CMD" ]; then
        APP_CMD="${APP_CMD} "
    fi
    APP_CMD="${APP_CMD}${QUOTED}"
done

# Litestream 负责接管子进程生命周期并处理优雅停机同步。应用和
# Litestream 使用同一用户，避免 SQLite 与 Litestream 元数据权限不一致。
if [ -n "${LITESTREAM_LOG_LEVEL:-}" ]; then
    exec_as_app litestream replicate -config "$CONFIG" -log-level "$LITESTREAM_LOG_LEVEL" -exec "$APP_CMD"
else
    exec_as_app litestream replicate -config "$CONFIG" -exec "$APP_CMD"
fi
