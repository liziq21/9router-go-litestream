#!/bin/sh
set -eu

IMAGE=${1:?usage: generic_container_test.sh IMAGE}
PORT=${2:-8080}
NAME="litestream-generic-${PORT}-$$"
DATA_DIR=$(mktemp -d)
REPLICA_DIR=$(mktemp -d)
chmod 777 "$DATA_DIR" "$REPLICA_DIR"
HOST_UID=$(id -u)
HOST_GID=$(id -g)

trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; docker run --rm -v "$DATA_DIR:/data" alpine:3.20 sh -c "find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +; chown $HOST_UID:$HOST_GID /data" >/dev/null 2>&1 || true; docker run --rm -v "$REPLICA_DIR:/replica" alpine:3.20 sh -c "find /replica -mindepth 1 -maxdepth 1 -exec rm -rf {} +; chown $HOST_UID:$HOST_GID /replica" >/dev/null 2>&1 || true; rm -rf "$DATA_DIR" "$REPLICA_DIR"' EXIT HUP INT TERM

wait_for_health() {
    ATTEMPTS=0
    while [ "$ATTEMPTS" -lt 30 ]; do
        if curl --fail --silent --show-error "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
            return 0
        fi
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 1
    done

    echo "Generic example did not become healthy: $IMAGE:$PORT" >&2
    docker logs "$NAME" >&2 || true
    return 1
}

# A generic image must fail when replication is requested without an explicit
# SQLite path. The image's DATA_DIR and DB_PATH are not implicit fallback paths.
if docker run --rm \
    -v "$DATA_DIR:/var/lib/generic-sqlite" \
    -v "$REPLICA_DIR:/replica" \
    -e LITESTREAM_MODE=required \
    -e LITESTREAM_REPLICA_URL=file:///replica/backup \
    "$IMAGE" >/dev/null 2>&1; then
    echo 'Expected generic image without LITESTREAM_DB_PATH to fail' >&2
    exit 1
fi

docker run -d \
    --name "$NAME" \
    -p "127.0.0.1:${PORT}:${PORT}" \
    -v "$DATA_DIR:/var/lib/generic-sqlite" \
    -v "$REPLICA_DIR:/replica" \
    -e LITESTREAM_MODE=required \
    -e LITESTREAM_DB_PATH=/var/lib/generic-sqlite/data.sqlite \
    -e LITESTREAM_REPLICA_URL=file:///replica/backup \
    "$IMAGE" >/dev/null

wait_for_health
curl --fail --silent --show-error "http://127.0.0.1:${PORT}/touch" >/dev/null
# The file replica's regular sync interval is one second. Allow the write to
# reach the replica before stopping the container; otherwise a fast CI runner
# can remove the only local copy before Litestream has produced a backup.
sleep 2
docker stop --time 30 "$NAME" >/dev/null
docker rm "$NAME" >/dev/null

docker run --rm \
    -v "$DATA_DIR:/var/lib/generic-sqlite" \
    alpine:3.20 sh -c 'rm -rf /var/lib/generic-sqlite/data.sqlite*'

docker run -d \
    --name "$NAME" \
    -p "127.0.0.1:${PORT}:${PORT}" \
    -v "$DATA_DIR:/var/lib/generic-sqlite" \
    -v "$REPLICA_DIR:/replica" \
    -e LITESTREAM_MODE=required \
    -e LITESTREAM_DB_PATH=/var/lib/generic-sqlite/data.sqlite \
    -e LITESTREAM_REPLICA_URL=file:///replica/backup \
    "$IMAGE" >/dev/null

wait_for_health
BODY=$(curl --fail --silent --show-error "http://127.0.0.1:${PORT}/health")
case "$BODY" in
    *'"touches": 1'*)
        ;;
    *)
        echo "Restored generic marker mismatch: $BODY" >&2
        docker logs "$NAME" >&2 || true
        exit 1
        ;;
esac

echo "generic container test: PASS ($IMAGE:$PORT)"
