#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ Server — Comprehensive end-to-end test suite.
#
# Starts the V-lang server, exercises every REST endpoint (health, menu,
# cartridge info for all 21 builtins, feedback-o-tron full cycle, order
# ticket), tests the MCP bridge JSON-RPC protocol, then tears everything
# down.
#
# Usage:
#   bash tests/e2e_full.sh
#
# Prerequisites:
#   - BoJ binary built (just build-adapter)
#   - Zig FFI libraries built (just build-ffi)
#   - curl, jq, node/deno on PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOJ_BIN="$PROJECT_DIR/adapter/v/boj-server"
MCP_BRIDGE="$PROJECT_DIR/mcp-bridge/main.js"
REST_PORT="${BOJ_REST_PORT:-7700}"
BASE_URL="http://localhost:${REST_PORT}"

# Library path for Zig FFI shared objects
export LD_LIBRARY_PATH="$PROJECT_DIR/ffi/zig/zig-out/lib:${LD_LIBRARY_PATH:-}"
for cart_lib in "$PROJECT_DIR"/cartridges/*/ffi/zig-out/lib; do
    [ -d "$cart_lib" ] && LD_LIBRARY_PATH="$cart_lib:$LD_LIBRARY_PATH"
done
export LD_LIBRARY_PATH

PASS=0
FAIL=0
SKIP=0
PIDS=()
TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/boj-e2e-test.XXXXXXXXXX")"

# ─── Colour helpers (match existing test style) ──────────────────────
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

# ─── Assertion helpers ────────────────────────────────────────────────

# check <label> <expected-substring> <actual>
check() {
    local name="$1" expected="$2" actual="$3"
    if echo "$actual" | grep -q "$expected"; then
        green "  PASS: $name"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $name (expected '$expected', got '${actual:0:120}')"
        FAIL=$((FAIL + 1))
    fi
}

# check_status <label> <expected-http-code> <url>
check_status() {
    local name="$1" expected="$2" url="$3"
    local code
    code=$(curl -sf -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    if [[ "$code" == "$expected" ]]; then
        green "  PASS: $name (HTTP $code)"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $name (expected HTTP $expected, got $code)"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Cleanup ──────────────────────────────────────────────────────────
cleanup() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -rf "$TMPDIR_TEST" 2>/dev/null || true
}
trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════════"
echo "  BoJ Server — Comprehensive E2E Test Suite"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── Preflight checks ────────────────────────────────────────────────
bold "Preflight: Checking prerequisites..."

if [[ ! -x "$BOJ_BIN" ]]; then
    red "  ERROR: BoJ binary not found at $BOJ_BIN"
    red "  Run 'just build-adapter' first."
    exit 1
fi
green "  BoJ binary found"

if ! command -v curl &>/dev/null; then
    red "  ERROR: curl not found on PATH"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    red "  ERROR: jq not found on PATH"
    exit 1
fi
green "  curl + jq available"

# Check for node or deno (MCP bridge)
MCP_RUNNER=""
if command -v deno &>/dev/null; then
    MCP_RUNNER="deno run --allow-net --allow-env"
elif command -v node &>/dev/null; then
    MCP_RUNNER="node"
fi
if [[ -n "$MCP_RUNNER" ]]; then
    green "  MCP bridge runner: $MCP_RUNNER"
else
    yellow "  SKIP: no node/deno found — MCP bridge tests will be skipped"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 1: Start the V-lang server
# ═══════════════════════════════════════════════════════════════════════
bold "Step 1: Starting BoJ server on port $REST_PORT..."
BOJ_REST_PORT="$REST_PORT" "$BOJ_BIN" > "$TMPDIR_TEST/boj-e2e-full.log" 2>&1 &
PIDS+=($!)

# Wait for health check (up to 10 seconds)
for i in $(seq 1 50); do
    if curl -sf "$BASE_URL/health" > /dev/null 2>&1; then
        green "  Server is up (waited ~$((i * 200))ms)"
        break
    fi
    if [[ $i -eq 50 ]]; then
        red "  ERROR: Server did not start within 10 seconds"
        red "  Log tail:"
        tail -20 "$TMPDIR_TEST/boj-e2e-full.log" 2>/dev/null || true
        exit 1
    fi
    sleep 0.2
done
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 2: Health check
# ═══════════════════════════════════════════════════════════════════════
bold "Step 2: Health check"
health=$(curl -sf "$BASE_URL/health" 2>/dev/null || echo "{}")
check "health endpoint returns ok" '"status":"ok"' "$health"
check "health contains version" '"version"' "$health"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 3: Menu fetch
# ═══════════════════════════════════════════════════════════════════════
bold "Step 3: Menu fetch"
menu=$(curl -sf "$BASE_URL/menu" 2>/dev/null || echo "{}")
check "menu endpoint returns data" '"tier_teranga"' "$menu"
check "menu contains teranga tier" 'teranga' "$menu"

# Count cartridges in the teranga tier
teranga_count=$(echo "$menu" | jq '.tier_teranga | length' 2>/dev/null || echo "0")
check "teranga tier has cartridges" "1" "$([ "$teranga_count" -gt 0 ] && echo 1 || echo 0)"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 4: Cartridge info for all 21 builtins (18 Teranga + 3 Shield)
# ═══════════════════════════════════════════════════════════════════════
bold "Step 4: Cartridge info — all 21 builtins"

# All registered builtins (Teranga tier)
TERANGA_CARTS=(
    database-mcp nesy-mcp fleet-mcp agent-mcp cloud-mcp container-mcp
    k8s-mcp git-mcp queues-mcp iac-mcp observe-mcp ssg-mcp
    lsp-mcp dap-mcp bsp-mcp feedback-mcp comms-mcp ml-mcp research-mcp
)

# Shield tier
SHIELD_CARTS=(secrets-mcp proof-mcp ums-mcp)

ALL_CARTS=("${TERANGA_CARTS[@]}" "${SHIELD_CARTS[@]}")

for cart in "${ALL_CARTS[@]}"; do
    info=$(curl -sf "$BASE_URL/cartridge/$cart" 2>/dev/null || echo "{}")
    check "cartridge/$cart returns info" '"name"' "$info"
done
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 5: Cartridge list endpoint
# ═══════════════════════════════════════════════════════════════════════
bold "Step 5: Cartridge list"
cart_list=$(curl -sf "$BASE_URL/cartridges" 2>/dev/null || echo "[]")
check "/cartridges returns array" '"name"' "$cart_list"
cart_count=$(echo "$cart_list" | jq 'length' 2>/dev/null || echo "0")
check "cartridge count >= 21" "1" "$([ "$cart_count" -ge 21 ] && echo 1 || echo 0)"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 6: Feedback-o-tron full cycle
# ═══════════════════════════════════════════════════════════════════════
bold "Step 6: Feedback-o-tron full cycle"

# 6a: Load feedback-mcp cartridge
load_result=$(curl -sf -X POST "$BASE_URL/cartridges/feedback-mcp/load" 2>/dev/null || echo "{}")
check "feedback-mcp load" '"status"' "$load_result"

# 6b: Register (open_channel)
reg_result=$(curl -sf -X POST "$BASE_URL/cartridges/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"open_channel","args":"{\"channel\":\"api\"}"}' 2>/dev/null || echo "{}")
check "feedback register (open_channel)" '"slot"' "$reg_result"
FEEDBACK_SLOT=$(echo "$reg_result" | jq -r '.slot // "0"' 2>/dev/null || echo "0")

# 6c: Submit feedback (positive)
submit_result=$(curl -sf -X POST "$BASE_URL/cartridges/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d "{\"tool\":\"submit\",\"args\":\"{\\\"slot\\\":\\\"${FEEDBACK_SLOT}\\\",\\\"sentiment\\\":\\\"positive\\\"}\"}" \
    2>/dev/null || echo "{}")
check "feedback submit (positive)" '"recorded"' "$submit_result"

# 6d: Submit feedback (negative)
submit_neg=$(curl -sf -X POST "$BASE_URL/cartridges/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d "{\"tool\":\"submit\",\"args\":\"{\\\"slot\\\":\\\"${FEEDBACK_SLOT}\\\",\\\"sentiment\\\":\\\"negative\\\"}\"}" \
    2>/dev/null || echo "{}")
check "feedback submit (negative)" '"recorded"' "$submit_neg"

# 6e: Summary
summary_result=$(curl -sf -X POST "$BASE_URL/cartridges/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"summary","args":"{}"}' 2>/dev/null || echo "{}")
check "feedback summary" '"total_feedback"' "$summary_result"

# 6f: Export
export_result=$(curl -sf -X POST "$BASE_URL/cartridges/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"export_feedback","args":"{}"}' 2>/dev/null || echo "{}")
check "feedback export" '"export_feedback"' "$export_result"

# 6g: Status check
status_result=$(curl -sf -X POST "$BASE_URL/cartridges/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"status","args":"{}"}' 2>/dev/null || echo "{}")
check "feedback status" '"feedback-o-tron"' "$status_result"

# 6h: Deregister — close the channel
# Note: deregister is done via the FFI fb_deregister; we test through
# the list_channels tool which should still work after channel close
list_result=$(curl -sf -X POST "$BASE_URL/cartridges/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"list_channels","args":"{}"}' 2>/dev/null || echo "{}")
check "feedback list_channels" '"available"' "$list_result"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 7: Order ticket flow
# ═══════════════════════════════════════════════════════════════════════
bold "Step 7: Order ticket"
order_result=$(curl -sf -X POST "$BASE_URL/order" \
    -H "Content-Type: application/json" \
    -d '{"cartridges":["database-mcp","git-mcp"]}' 2>/dev/null || echo "{}")
check "order ticket returns result" '"order"' "$order_result"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 8: MCP Bridge (JSON-RPC over stdio)
# ═══════════════════════════════════════════════════════════════════════
bold "Step 8: MCP bridge"

if [[ -z "$MCP_RUNNER" ]]; then
    yellow "  SKIP: no node/deno — MCP bridge tests skipped"
    SKIP=$((SKIP + 3))
else
    if [[ ! -f "$MCP_BRIDGE" ]]; then
        yellow "  SKIP: MCP bridge not found at $MCP_BRIDGE"
        SKIP=$((SKIP + 3))
    else
        # 8a: Initialize — send JSON-RPC initialize
        init_response=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e-test","version":"1.0.0"}}}' \
            | timeout 5 $MCP_RUNNER "$MCP_BRIDGE" 2>/dev/null | head -1 || echo "{}")
        check "MCP initialize" '"result"' "$init_response"

        # 8b: List tools
        tools_response=$(echo -e '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e-test","version":"1.0.0"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
            | timeout 5 $MCP_RUNNER "$MCP_BRIDGE" 2>/dev/null | tail -1 || echo "{}")
        check "MCP tools/list" '"tools"' "$tools_response"

        # 8c: Call boj_health tool
        health_response=$(echo -e '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"e2e-test","version":"1.0.0"}}}\n{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"boj_health","arguments":{}}}' \
            | timeout 5 $MCP_RUNNER "$MCP_BRIDGE" 2>/dev/null | tail -1 || echo "{}")
        check "MCP tools/call boj_health" '"result"' "$health_response"
    fi
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 9: Negative tests
# ═══════════════════════════════════════════════════════════════════════
bold "Step 9: Negative / boundary tests"

# Non-existent cartridge
bad_cart=$(curl -sf -o /dev/null -w '%{http_code}' "$BASE_URL/cartridge/nonexistent-mcp" 2>/dev/null || echo "000")
check "non-existent cartridge returns 404" "404" "$bad_cart"

# Invalid order
bad_order=$(curl -sf -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/order" \
    -H "Content-Type: application/json" \
    -d '{"cartridges":["does-not-exist"]}' 2>/dev/null || echo "000")
check "invalid order returns error code" "1" "$([ "$bad_order" != "200" ] && echo 1 || echo 0)"

# Malformed JSON to invoke
bad_invoke=$(curl -sf -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/cartridges/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d 'not-json' 2>/dev/null || echo "000")
check "malformed JSON invoke returns error" "1" "$([ "$bad_invoke" != "200" ] && echo 1 || echo 0)"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL + SKIP))
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped (of $TOTAL)"
if [ $FAIL -eq 0 ]; then
    green "  E2E Full: ALL PASS"
else
    red "  E2E Full: $FAIL FAILURES"
fi
echo "═══════════════════════════════════════════════════════════════"

exit "$FAIL"
