#!/bin/sh
# SPDX-License-Identifier: PMPL-1.0-or-later
# Bundle of Joy Server container entrypoint
#
# Handles signal propagation, startup logging, and health check
# preparation before exec-ing into the main application process.

set -e

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------
#
# Trap SIGTERM and SIGINT so that the application can shut down gracefully
# when Podman sends stop signals (e.g. `podman stop`, `selur-compose down`).

cleanup() {
    echo "Received shutdown signal — stopping boj-server..."
    # If the main process is backgrounded, kill it here:
    # kill "$MAIN_PID" 2>/dev/null || true
    # wait "$MAIN_PID" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# ---------------------------------------------------------------------------
# Startup logging
# ---------------------------------------------------------------------------

# Build LD_LIBRARY_PATH dynamically from all cartridge lib directories
CART_LIBS=""
for lib_dir in /app/lib/cartridges/*/lib; do
    if [ -d "$lib_dir" ]; then
        CART_LIBS="${CART_LIBS:+${CART_LIBS}:}${lib_dir}"
    fi
done
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+${LD_LIBRARY_PATH}:}${CART_LIBS}"

echo "Starting boj-server..."
echo "  Host: ${APP_HOST:-[::]}"
echo "  Port: ${APP_PORT:-7700}"
echo "  Data: ${APP_DATA_DIR:-/data}"
echo "  Log:  ${APP_LOG_FORMAT:-json}"
echo "  Libs: $(echo "$LD_LIBRARY_PATH" | tr ':' '\n' | wc -l) library paths"

# ---------------------------------------------------------------------------
# Health check preparation
# ---------------------------------------------------------------------------
#
# Ensure the data directory exists and is writable.
# The VOLUME directive in the Containerfile creates /data, but a bind-mount
# might replace it with an empty directory owned by root.

if [ -d "${APP_DATA_DIR:-/data}" ]; then
    if [ ! -w "${APP_DATA_DIR:-/data}" ]; then
        echo "WARNING: ${APP_DATA_DIR:-/data} is not writable by $(whoami)"
    fi
fi

# ---------------------------------------------------------------------------
# Node ID auto-generation
# ---------------------------------------------------------------------------
#
# If BOJ_NODE_ID is not set, generate a stable one from the hostname.
# Persist to DATA_DIR so identity survives restarts.

DATA_DIR="${APP_DATA_DIR:-/data}"
NODE_ID_FILE="${DATA_DIR}/.node-id"

if [ -z "${BOJ_NODE_ID:-}" ]; then
    if [ -f "$NODE_ID_FILE" ]; then
        BOJ_NODE_ID=$(cat "$NODE_ID_FILE")
    else
        # Generate from hostname + random suffix
        SUFFIX=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')
        BOJ_NODE_ID="node-$(hostname -s)-${SUFFIX}"
        if [ -w "$DATA_DIR" ]; then
            echo "$BOJ_NODE_ID" > "$NODE_ID_FILE"
        fi
    fi
    export BOJ_NODE_ID
fi
echo "  Node: ${BOJ_NODE_ID}"

# ---------------------------------------------------------------------------
# Federation auto-seed (background)
# ---------------------------------------------------------------------------
#
# After the main process starts, wait for the REST API to be healthy,
# then POST each seed node to /umoja/peers. Uses BOJ_SEED_NODES env
# (comma-separated host:port) or falls back to the built-in seeds.

DEFAULT_SEEDS="eu.boj.hyperpolymath.dev:9999,de.boj.hyperpolymath.dev:9999,us.boj.hyperpolymath.dev:9999,ap.boj.hyperpolymath.dev:9999"
SEEDS="${BOJ_SEED_NODES:-$DEFAULT_SEEDS}"
REST_PORT="${APP_PORT:-7700}"

bootstrap_federation() {
    # Wait for the REST API to become available
    TRIES=0
    MAX_TRIES=20
    while [ "$TRIES" -lt "$MAX_TRIES" ]; do
        if curl -sf "http://localhost:${REST_PORT}/health" > /dev/null 2>&1; then
            break
        fi
        TRIES=$((TRIES + 1))
        sleep 1
    done

    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
        echo "WARNING: REST API did not become healthy — skipping federation bootstrap"
        return
    fi

    # Add each seed node as a peer
    echo "Bootstrapping federation with seed nodes..."
    IFS=','
    for seed in $SEEDS; do
        host=$(echo "$seed" | cut -d: -f1)
        port=$(echo "$seed" | cut -d: -f2)
        curl -sf -X POST "http://localhost:${REST_PORT}/umoja/peers" \
            -H "Content-Type: application/json" \
            -d "{\"host\":\"${host}\",\"port\":${port}}" > /dev/null 2>&1 \
            && echo "  Seeded: ${host}:${port}" \
            || echo "  Seed unreachable: ${host}:${port} (will retry via gossip)"
    done
    unset IFS
    echo "Federation bootstrap complete"
}

# Run bootstrap in background so exec happens immediately
bootstrap_federation &

# ---------------------------------------------------------------------------
# Exec into main process
# ---------------------------------------------------------------------------
#
# Replace the entrypoint shell with the application process so that
# signals are delivered directly and PID 1 is the application.

exec /app/boj-server serve --host "${APP_HOST:-[::]}" --port "${REST_PORT}"
