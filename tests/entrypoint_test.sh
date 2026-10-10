#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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

cat > "$BIN_DIR/litestream" <<'EOF'
#!/bin/sh
: > "$ARGS_FILE"
if [ -n "${ENV_FILE:-}" ]; then
    printf 'DATA_DIR=%s\n' "$DATA_DIR" > "$ENV_FILE"
    printf 'DB_PATH=%s\n' "$DB_PATH" >> "$ENV_FILE"
fi
INDEX=1
for ARG do
    printf '%s=%s\n' "$INDEX" "$ARG" >> "$ARGS_FILE"
    INDEX=$((INDEX + 1))
done
EOF

chmod +x "$BIN_DIR/9router-go" "$BIN_DIR/litestream"

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
ARGS_FILE="$APP_ARGS" PATH="$BIN_DIR:$PATH" "$ENTRYPOINT" 9router-go "two words" "a'b"
assert_line '1=two words' "$APP_ARGS"
assert_line "2=a'b" "$APP_ARGS"
[ "$(wc -l < "$APP_ARGS")" -eq 2 ]

# No arguments must still run the default application command.
ARGS_FILE="$APP_ARGS" PATH="$BIN_DIR:$PATH" "$ENTRYPOINT"
[ ! -s "$APP_ARGS" ]

# Litestream mode receives one shell command string that preserves all arguments.
LITESTREAM_ARGS="$TMP_DIR/litestream.args"
LITESTREAM_ENV="$TMP_DIR/litestream.env"
env -u DATA_DIR -u DB_PATH \
    ARGS_FILE="$LITESTREAM_ARGS" ENV_FILE="$LITESTREAM_ENV" \
    REPLICA_URL='s3://bucket/db' PATH="$BIN_DIR:$PATH" \
    "$ENTRYPOINT" 9router-go "two words" "a'b"
assert_line '1=replicate' "$LITESTREAM_ARGS"
assert_line '2=-config' "$LITESTREAM_ARGS"
assert_line '3=/etc/litestream.yml' "$LITESTREAM_ARGS"
assert_line '4=-exec' "$LITESTREAM_ARGS"
EXPECTED_EXEC="'9router-go' 'two words' 'a'\\''b'"
assert_line "5=$EXPECTED_EXEC" "$LITESTREAM_ARGS"
[ "$(wc -l < "$LITESTREAM_ARGS")" -eq 5 ]
assert_line 'DATA_DIR=/data' "$LITESTREAM_ENV"
assert_line 'DB_PATH=/data/db/data.sqlite' "$LITESTREAM_ENV"

# Replication mode must reject a database path Litestream does not monitor.
if DATA_DIR=/wrong DB_PATH=/data/db/data.sqlite REPLICA_URL='s3://bucket/db' \
    PATH="$BIN_DIR:$PATH" "$ENTRYPOINT" 9router-go >/dev/null 2>&1; then
    echo 'Expected mismatched database path to be rejected' >&2
    exit 1
fi

echo 'entrypoint tests: PASS'
