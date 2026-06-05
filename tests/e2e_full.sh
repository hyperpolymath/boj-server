#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ Server — Comprehensive end-to-end test suite.
#
# Starts the Elixir backend, exercises every REST endpoint (health, menu,
# cartridge info for all 21 builtins, feedback-o-tron full cycle via the
# unified /cartridge/:name/invoke dispatcher), tests the MCP bridge
# JSON-RPC protocol, then tears everything down.
#
# Order-ticket flow is NOT exercised here — it is covered at the Zig FFI
# layer by tests/order_ticket_e2e.sh. There is no `/order` HTTP endpoint
# on the Elixir router (see boj-server#151).
#
# Usage:
#   bash tests/e2e_full.sh
#
# Prerequisites:
#   - Elixir backend available (elixir/ dir + mix on PATH)
#   - Zig FFI libraries built (just build-ffi)
#   - curl, jq, node/deno on PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ELIXIR_DIR="$PROJECT_DIR/elixir"
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

if [[ ! -d "$ELIXIR_DIR" ]] || ! command -v mix &>/dev/null; then
    red "  ERROR: Elixir backend not available (need $ELIXIR_DIR and 'mix')"
    red "  Install Elixir/Mix; the BoJ REST surface is the Elixir backend."
    exit 1
fi
green "  Elixir backend found"

if ! command -v curl &>/dev/null; then
    red "  ERROR: curl not found on PATH"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    red "  ERROR: jq not found on PATH"
    exit 1
fi
green "  curl + jq available"

# Check for node or deno (MCP bridge).
# mcp-bridge/main.js requires --allow-read for nickel-validator.js (loads
# .ncl contracts) — the shebang says so, but `deno run <file>` ignores
# the shebang and uses only the flags passed to the CLI invocation.
# Without --allow-read, the bridge crashes on import with NotCapable
# and the test sees empty stdout (saw on PR #150 CI 2026-05-25).
MCP_RUNNER=""
if command -v deno &>/dev/null; then
    MCP_RUNNER="deno run --allow-net --allow-env --allow-read"
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
# Step 1: Start the Elixir REST server
# ═══════════════════════════════════════════════════════════════════════
bold "Step 1: Starting BoJ server on port $REST_PORT..."
( cd "$ELIXIR_DIR" && BOJ_REST_PORT="$REST_PORT" mix run --no-halt ) > "$TMPDIR_TEST/boj-e2e-full.log" 2>&1 &
PIDS+=($!)

# Wait for health check (up to 60 seconds — CI cold start can compile
# Elixir deps on the critical path even when the workflow pre-runs
# `mix deps.get` / `mix compile`; local runs typically come up in <1s).
WAIT_ITERS=300
for i in $(seq 1 $WAIT_ITERS); do
    if curl -sf "$BASE_URL/health" > /dev/null 2>&1; then
        green "  Server is up (waited ~$((i * 200))ms)"
        break
    fi
    if [[ $i -eq $WAIT_ITERS ]]; then
        red "  ERROR: Server did not start within $((WAIT_ITERS * 200 / 1000)) seconds"
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
cart_list=$(curl -sf "$BASE_URL/cartridges" 2>/dev/null || echo "{}")
check "/cartridges returns catalogue" '"cartridges"' "$cart_list"
cart_count=$(echo "$cart_list" | jq '.cartridges | length' 2>/dev/null || echo "0")
check "cartridge count >= 21" "1" "$([ "$cart_count" -ge 21 ] && echo 1 || echo 0)"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Step 6: Feedback-o-tron full cycle
# ═══════════════════════════════════════════════════════════════════════
# Cartridges auto-load via BojRest.Catalog at server boot — there is no
# explicit /load route. All tool dispatches go through the unified
# POST /cartridge/:name/invoke endpoint (singular `cartridge`).
bold "Step 6: Feedback-o-tron full cycle"

# All dispatches go through the unified POST /cartridge/:name/invoke endpoint,
# which shells out (per ADR-0005) to the boj-invoke CLI fork-per-request. Each
# invoke is a FRESH process, so the cartridge's in-memory channel state does NOT
# persist between HTTP calls. feedback_submit is therefore self-provisioning — a
# single call registers + collects + records. Cross-call accumulation (the full
# multi-step state machine) belongs to the pooled-invoker follow-up and is
# covered by the in-process Zig unit test; here we assert only what a stateless
# invoker can truthfully deliver. Args go under "arguments" (forwarded by BojRest).

# 6a: Register a channel (FeedbackChannel.api_endpoint = 2) — returns a real slot
reg_result=$(curl -sf -X POST "$BASE_URL/cartridge/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"feedback_register_channel","arguments":{"channel":2}}' 2>/dev/null || echo "{}")
check "feedback register channel" '"slot"' "$reg_result"

# 6b: Submit positive — self-provisioning, records in a single stateless call
submit_pos=$(curl -sf -X POST "$BASE_URL/cartridge/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"feedback_submit","arguments":{"slot":0,"sentiment":1}}' 2>/dev/null || echo "{}")
check "feedback submit (positive) recorded" '"recorded":true' "$submit_pos"

# 6c: Submit negative — likewise records in one call
submit_neg=$(curl -sf -X POST "$BASE_URL/cartridge/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"feedback_submit","arguments":{"slot":0,"sentiment":-1}}' 2>/dev/null || echo "{}")
check "feedback submit (negative) recorded" '"recorded":true' "$submit_neg"

# 6d: Stats — returns the real stats shape (counts are per-call under the
#     stateless invoker, so accumulation is intentionally not asserted here)
stats_result=$(curl -sf -X POST "$BASE_URL/cartridge/feedback-mcp/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"feedback_get_stats","arguments":{"slot":0}}' 2>/dev/null || echo "{}")
check "feedback get_stats shape" '"total_feedback"' "$stats_result"
echo ""

# Step 7 (order-ticket flow) lives in tests/order_ticket_e2e.sh against
# the Zig FFI catalogue — the Elixir router has no /order route. See #151.

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

# Invoke against non-existent cartridge — exercises the 404 branch in
# the unified dispatcher (Step 7's old "invalid order returns error"
# previously tested an analogous negative case against /order, which
# doesn't exist; this is the equivalent at the cartridge layer).
bad_dispatch=$(curl -sf -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/cartridge/does-not-exist/invoke" \
    -H "Content-Type: application/json" \
    -d '{"tool":"noop","args":"{}"}' 2>/dev/null || echo "000")
check "invoke against unknown cartridge returns 404" "404" "$bad_dispatch"

# Malformed JSON to invoke
bad_invoke=$(curl -sf -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/cartridge/feedback-mcp/invoke" \
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
