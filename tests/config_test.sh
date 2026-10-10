#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOCKERFILE="$ROOT_DIR/Dockerfile"
LITESTREAM_CONFIG="$ROOT_DIR/litestream.yml"

assert_contains() {
    EXPECTED=$1
    FILE=$2
    if ! grep -Fqx "$EXPECTED" "$FILE"; then
        echo "Expected '$EXPECTED' in $FILE" >&2
        exit 1
    fi
}

# The application and Litestream must use the same SQLite database path.
assert_contains 'ENV DATA_DIR=/data \' "$DOCKERFILE"
assert_contains '    DB_PATH=/data/db/data.sqlite' "$DOCKERFILE"
assert_contains '  - path: /data/db/data.sqlite' "$LITESTREAM_CONFIG"

echo 'configuration tests: PASS'
