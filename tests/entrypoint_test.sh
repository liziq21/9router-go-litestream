#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
ENTRYPOINT="$ROOT_DIR/entrypoint.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/9router-go" <<'EOF'
#!/bin/sh
: > "$ARGS_FILE"
INDEX=1
for ARG do
    printf '%s=%s\n' "$INDEX" "$ARG" >> "$ARGS_FILE"
    INDEX=$((INDEX + 1))
done
EOF

cat > "$BIN_DIR/custom-app" <<'EOF'
#!/bin/sh
: > "$ARGS_FILE"
EOF

cat > "$BIN_DIR/litestream" <<'EOF'
#!/bin/sh
: > "$ARGS_FILE"
if [ -n "${ENV_FILE:-}" ]; then
    printf 'DATA_DIR=%s\n' "${DATA_DIR:-}" > "$ENV_FILE"
    printf 'DB_PATH=%s\n' "${DB_PATH:-}" >> "$ENV_FILE"
    printf 'LITESTREAM_DB_PATH=%s\n' "${LITESTREAM_DB_PATH:-}" >> "$ENV_FILE"
    printf 'LITESTREAM_REPLICA_URL=%s\n' "${LITESTREAM_REPLICA_URL:-}" >> "$ENV_FILE"
fi
INDEX=1
for ARG do
    printf '%s=%s\n' "$INDEX" "$ARG" >> "$ARGS_FILE"
    INDEX=$((INDEX + 1))
done
EOF

chmod +x "$BIN_DIR/9router-go" "$BIN_DIR/custom-app" "$BIN_DIR/litestream"

cat > "$BIN_DIR/su-exec" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
chmod +x "$BIN_DIR/su-exec"

cat > "$BIN_DIR/chown" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BIN_DIR/chown"

assert_line() {
    EXPECTED=$1
    FILE=$2
    if ! grep -Fqx "$EXPECTED" "$FILE"; then
        echo "Expected '$EXPECTED' in $FILE" >&2
        echo 'Actual:' >&2
        cat "$FILE" >&2
        exit 1
    fi
}

# No-replication mode must preserve argument boundaries.
APP_ARGS="$TMP_DIR/app.args"
env -u REPLICA_URL -u LITESTREAM_REPLICA_URL \
    ARGS_FILE="$APP_ARGS" PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" 9router-go "two words" "a'b"
assert_line '1=two words' "$APP_ARGS"
assert_line "2=a'b" "$APP_ARGS"
[ "$(wc -l < "$APP_ARGS")" -eq 2 ]

# An explicit compatibility default may be used without making the generic
# wrapper depend on a fixed application command.
env -u REPLICA_URL -u LITESTREAM_REPLICA_URL \
    APP_DEFAULT_COMMAND=9router-go ARGS_FILE="$APP_ARGS" PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT"
[ ! -s "$APP_ARGS" ]

# Without Docker CMD positional arguments or an explicit test default, the
# wrapper must fail instead of silently choosing an application.
if env -u REPLICA_URL -u LITESTREAM_REPLICA_URL \
    -u APP_DEFAULT_COMMAND ARGS_FILE="$APP_ARGS" PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" >/dev/null 2>&1; then
    echo 'Expected missing application command to fail' >&2
    exit 1
fi

# Disabled mode must bypass Litestream even if a replica URL is present.
ARGS_FILE="$APP_ARGS" LITESTREAM_MODE=disabled REPLICA_URL='s3://bucket/db' \
    PATH="$BIN_DIR:$PATH" "$ENTRYPOINT" custom-app
[ ! -s "$APP_ARGS" ]

# Profile application and Litestream processes may use the same explicit user.
env -u REPLICA_URL -u LITESTREAM_REPLICA_URL \
    ARGS_FILE="$APP_ARGS" APP_USER=node DATA_DIR="$TMP_DIR/app-data" \
    PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" custom-app
[ ! -s "$APP_ARGS" ]

# Required mode must fail before the application starts without a replica URL.
if env -u REPLICA_URL -u LITESTREAM_REPLICA_URL \
    ARGS_FILE="$APP_ARGS" LITESTREAM_MODE=required PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" custom-app >/dev/null 2>&1; then
    echo 'Expected required mode without a replica URL to fail' >&2
    exit 1
fi

# Generic replication must not guess a database path from DATA_DIR or DB_PATH.
if env -u LITESTREAM_DB_PATH \
    ARGS_FILE="$APP_ARGS" LITESTREAM_REPLICA_URL='s3://bucket/db' \
    DATA_DIR="$TMP_DIR/generic-data" DB_PATH="$TMP_DIR/generic-data/data.sqlite" \
    PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" custom-app >/dev/null 2>&1; then
    echo 'Expected generic replication without LITESTREAM_DB_PATH to fail' >&2
    exit 1
fi

# New variables take precedence over the legacy REPLICA_URL variable and all
# arguments are passed to Litestream as one safely quoted shell command.
LITESTREAM_ARGS="$TMP_DIR/litestream.args"
LITESTREAM_ENV="$TMP_DIR/litestream.env"
env -u DATA_DIR -u DB_PATH \
    ARGS_FILE="$LITESTREAM_ARGS" ENV_FILE="$LITESTREAM_ENV" \
    LITESTREAM_DB_PATH="$TMP_DIR/db/data.sqlite" \
    LITESTREAM_REPLICA_URL='s3://bucket/new-db' REPLICA_URL='s3://bucket/old-db' \
    PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" 9router-go "two words" "a'b"
assert_line '1=replicate' "$LITESTREAM_ARGS"
assert_line '2=-config' "$LITESTREAM_ARGS"
assert_line '3=/etc/litestream.yml' "$LITESTREAM_ARGS"
assert_line '4=-exec' "$LITESTREAM_ARGS"
EXPECTED_EXEC="'9router-go' 'two words' 'a'\\''b'"
assert_line "5=$EXPECTED_EXEC" "$LITESTREAM_ARGS"
[ "$(wc -l < "$LITESTREAM_ARGS")" -eq 5 ]
assert_line 'DATA_DIR=' "$LITESTREAM_ENV"
assert_line 'DB_PATH=' "$LITESTREAM_ENV"
assert_line "LITESTREAM_DB_PATH=$TMP_DIR/db/data.sqlite" "$LITESTREAM_ENV"
assert_line 'LITESTREAM_REPLICA_URL=s3://bucket/new-db' "$LITESTREAM_ENV"

# A requested Litestream log level must be passed through without exposing the
# replica URL or credentials in the diagnostic output.
DEBUG_ARGS="$TMP_DIR/litestream-debug.args"
env -u DATA_DIR -u DB_PATH \
    ARGS_FILE="$DEBUG_ARGS" LITESTREAM_DB_PATH="$TMP_DIR/debug/data.sqlite" \
    LITESTREAM_REPLICA_URL='s3://bucket/debug-db' LITESTREAM_LOG_LEVEL=debug \
    LITESTREAM_ACCESS_KEY_ID='test-access-key' \
    LITESTREAM_SECRET_ACCESS_KEY='test-secret-key' PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" custom-app >/dev/null 2>"$TMP_DIR/debug.log"
assert_line '1=replicate' "$DEBUG_ARGS"
assert_line '2=-config' "$DEBUG_ARGS"
assert_line '3=/etc/litestream.yml' "$DEBUG_ARGS"
assert_line '4=-log-level' "$DEBUG_ARGS"
assert_line '5=debug' "$DEBUG_ARGS"
assert_line '6=-exec' "$DEBUG_ARGS"
assert_line "7='custom-app'" "$DEBUG_ARGS"
if ! grep -Fq '[Entrypoint] startup mode=auto config=/etc/litestream.yml' "$TMP_DIR/debug.log"; then
    echo 'Expected startup diagnostics in the entrypoint log' >&2
    exit 1
fi
if ! grep -Fq '[Entrypoint] runtime uid=' "$TMP_DIR/debug.log"; then
    echo 'Expected runtime identity diagnostics in the entrypoint log' >&2
    exit 1
fi
if grep -Eq 'test-access-key|test-secret-key|s3://bucket/debug-db' "$TMP_DIR/debug.log"; then
    echo 'Credentials and the replica URL must not appear in diagnostic output' >&2
    exit 1
fi

# The legacy variable remains supported when the new variable is absent.
LEGACY_ARGS="$TMP_DIR/legacy.args"
LEGACY_ENV="$TMP_DIR/legacy.env"
env -u LITESTREAM_REPLICA_URL \
    ARGS_FILE="$LEGACY_ARGS" ENV_FILE="$LEGACY_ENV" \
    LITESTREAM_DB_PATH="$TMP_DIR/legacy/data.sqlite" \
    REPLICA_URL='s3://bucket/legacy-db' PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" custom-app
assert_line 'LITESTREAM_REPLICA_URL=s3://bucket/legacy-db' "$LEGACY_ENV"

# A profile path contract must reject an application path Litestream does not
# monitor.
if DATA_DIR=/wrong DB_PATH=/data/db/data.sqlite \
    LITESTREAM_DB_PATH=/data/db/data.sqlite \
    LITESTREAM_EXPECTED_DATA_DIR=/data \
    LITESTREAM_EXPECTED_DB_PATH=/data/db/data.sqlite \
    LITESTREAM_REPLICA_URL='s3://bucket/db' PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" 9router-go >/dev/null 2>&1; then
    echo 'Expected mismatched data path to be rejected' >&2
    exit 1
fi

echo 'entrypoint tests: PASS'
