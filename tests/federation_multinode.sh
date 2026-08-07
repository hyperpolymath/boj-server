#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ Server — Multi-node federation test
#
# Spawns two BoJ instances on separate ports with separate federation ports,
# peers them via the REST API, and verifies gossip/heartbeat connectivity.
#
# Usage:
#   bash tests/federation_multinode.sh
#
# Prerequisites:
#   - Elixir backend available (elixir/ dir + mix on PATH)
#   - curl, jq on PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ELIXIR_DIR="$PROJECT_DIR/elixir"

# Cartridge catalog root: the bundled cartridges/ tree was retired in favour
# of hyperpolymath/boj-server-cartridges. Default to the tracked fixture
# catalogue; point BOJ_CARTRIDGES_PATH at a cache populated by
# scripts/fetch-cartridges.sh to load real cartridge .so files.
export BOJ_CARTRIDGES_PATH="${BOJ_CARTRIDGES_PATH:-$PROJECT_DIR/tests/fixtures/cartridges}"

# Library path for Zig FFI shared objects. The old hard-coded
# cartridges/container-mcp/ffi/zig-out/lib entry pointed into the deleted
# tree, so it silently contributed nothing; take every cartridge lib dir
# that actually exists under the catalog root instead (as tests/e2e_full.sh
# does).
export LD_LIBRARY_PATH="$PROJECT_DIR/ffi/zig/zig-out/lib:${LD_LIBRARY_PATH:-}"
for cart_lib in "$BOJ_CARTRIDGES_PATH"/*/ffi/zig-out/lib; do
    [ -d "$cart_lib" ] && LD_LIBRARY_PATH="$cart_lib:$LD_LIBRARY_PATH"
done
export LD_LIBRARY_PATH

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
PIDS=()
TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/boj-fed-test.XXXXXXXXXX")"

cleanup() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_empty() {
    local label="$1" actual="$2"
    if [[ -n "$actual" ]]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label (empty)"
        FAIL=$((FAIL + 1))
    fi
}

echo "================================================================="
echo "  BoJ Server — Multi-Node Federation Test"
echo "================================================================="
echo ""

if [[ ! -d "$ELIXIR_DIR" ]] || ! command -v mix &>/dev/null; then
    red "ERROR: Elixir backend not available (need $ELIXIR_DIR and 'mix')"
    red "The BoJ REST surface is the Elixir backend."
    exit 1
fi

# ─── Node A: REST 7710, gRPC 7711, GraphQL 7712, Federation 9910 ───
bold "Starting Node A (ports 7710/9910)..."
( cd "$ELIXIR_DIR" && BOJ_REST_PORT=7710 BOJ_GRPC_PORT=7711 BOJ_GRAPHQL_PORT=7712 \
    BOJ_FEDERATION_PORT=9910 BOJ_QUIC=1 \
    BOJ_NODE_ID="node-alpha" BOJ_REGION="eu-west-1" \
    mix run --no-halt ) > "$TMPDIR_TEST/boj-node-a.log" 2>&1 &
PIDS+=($!)

# ─── Node B: REST 7720, gRPC 7721, GraphQL 7722, Federation 9920 ───
bold "Starting Node B (ports 7720/9920)..."
( cd "$ELIXIR_DIR" && BOJ_REST_PORT=7720 BOJ_GRPC_PORT=7721 BOJ_GRAPHQL_PORT=7722 \
    BOJ_FEDERATION_PORT=9920 BOJ_QUIC=1 \
    BOJ_NODE_ID="node-bravo" BOJ_REGION="us-east-1" \
    mix run --no-halt ) > "$TMPDIR_TEST/boj-node-b.log" 2>&1 &
PIDS+=($!)

# Wait for both nodes to be ready
bold "Waiting for nodes to start..."
for port in 7710 7720; do
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:$port/health" > /dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
done
echo ""

# ─── Test 1: Both nodes report healthy ───
bold "Test 1: Node health checks"
status_a=$(curl -sf "http://localhost:7710/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "")
status_b=$(curl -sf "http://localhost:7720/health" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "")
assert_eq "Node A healthy" "ok" "$status_a"
assert_eq "Node B healthy" "ok" "$status_b"
echo ""

# ─── Test 2: Federation status ───
bold "Test 2: Federation status"
fed_a=$(curl -sf "http://localhost:7710/umoja/status" 2>/dev/null || echo "{}")
fed_b=$(curl -sf "http://localhost:7720/umoja/status" 2>/dev/null || echo "{}")

bound_a=$(echo "$fed_a" | jq -r '.bound' 2>/dev/null || echo "")
bound_b=$(echo "$fed_b" | jq -r '.bound' 2>/dev/null || echo "")
transport_a=$(echo "$fed_a" | jq -r '.transport' 2>/dev/null || echo "")

assert_eq "Node A bound" "1" "$bound_a"
assert_eq "Node B bound" "1" "$bound_b"
assert_eq "Node A transport is quic" "quic" "$transport_a"
echo ""

# ─── Test 3: Peer each node to the other ───
bold "Test 3: Add peers"
add_result=$(curl -sf -X POST "http://localhost:7710/umoja/peers" \
    -H "Content-Type: application/json" \
    -d '{"host":"127.0.0.1","port":"9920"}' 2>/dev/null || echo "{}")
add_status=$(echo "$add_result" | jq -r '.status' 2>/dev/null || echo "")
assert_eq "Node A peers Node B" "added" "$add_status"

add_result2=$(curl -sf -X POST "http://localhost:7720/umoja/peers" \
    -H "Content-Type: application/json" \
    -d '{"host":"127.0.0.1","port":"9910"}' 2>/dev/null || echo "{}")
add_status2=$(echo "$add_result2" | jq -r '.status' 2>/dev/null || echo "")
assert_eq "Node B peers Node A" "added" "$add_status2"
echo ""

# ─── Test 4: Peer counts updated ───
bold "Test 4: Peer counts"
peers_a=$(curl -sf "http://localhost:7710/umoja/peers" 2>/dev/null | jq -r '.count' 2>/dev/null || echo "0")
peers_b=$(curl -sf "http://localhost:7720/umoja/peers" 2>/dev/null | jq -r '.count' 2>/dev/null || echo "0")
assert_eq "Node A has 1 peer" "1" "$peers_a"
assert_eq "Node B has 1 peer" "1" "$peers_b"
echo ""

# ─── Test 5: Transport mode ───
bold "Test 5: Transport mode endpoint"
mode_a=$(curl -sf "http://localhost:7710/umoja/transport" 2>/dev/null | jq -r '.mode' 2>/dev/null || echo "")
assert_eq "Node A transport mode" "quic" "$mode_a"
echo ""

# ─── Test 6: Packets counters (baseline) ───
bold "Test 6: Packet counters"
sent_a=$(curl -sf "http://localhost:7710/umoja/status" 2>/dev/null | jq -r '.packets_sent' 2>/dev/null || echo "")
assert_not_empty "Node A packets_sent counter exists" "$sent_a"
echo ""

# ─── Summary ───
echo "================================================================="
total=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
    green "  ALL $total TESTS PASSED"
else
    red "  $FAIL/$total TESTS FAILED"
fi
echo "================================================================="

exit "$FAIL"
