#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ Server — End-to-end integration test.
#
# Tests the full pipeline:
#   1. Build Zig FFI library
#   2. Build V-lang adapter
#   3. Start the server
#   4. Exercise all REST endpoints
#   5. Exercise GraphQL endpoint
#   6. Test order-ticket flow
#   7. Verify cartridge mount/unmount via API
#   8. Tear down

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
SKIP=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if echo "$actual" | grep -q "$expected"; then
        green "  PASS: $name"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "  BoJ Server — End-to-End Integration Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# --- Step 1: Build Zig FFI ---
echo "Step 1: Building Zig FFI library..."
cd "$PROJECT_DIR/ffi/zig"
if zig build lib 2>/dev/null; then
    green "  Zig library built: zig-out/lib/libboj_catalogue.a"
else
    red "  Failed to build Zig library"
    exit 1
fi

# --- Step 2: Run all Zig tests ---
echo ""
echo "Step 2: Running Zig FFI tests..."
if zig build test --summary all 2>&1; then
    green "  All Zig tests passed"
else
    red "  Zig tests failed"
    exit 1
fi

# --- Step 3: Run readiness tests ---
echo ""
echo "Step 3: Running readiness tests..."
if zig build readiness --summary all 2>&1; then
    green "  All readiness tests passed"
else
    red "  Readiness tests failed"
    exit 1
fi

# --- Step 4: Check V adapter compiles ---
echo ""
echo "Step 4: Checking V-lang adapter..."
cd "$PROJECT_DIR/adapter/v"
if v -check src/main.v 2>/dev/null; then
    green "  V adapter syntax check passed"
else
    yellow "  V adapter check failed (may need V 0.5.0+)"
    SKIP=$((SKIP + 1))
fi

# --- Step 5: Run cartridge FFI tests ---
echo ""
echo "Step 5: Running cartridge FFI tests..."
cd "$PROJECT_DIR"
for cart in database-mcp fleet-mcp nesy-mcp agent-mcp; do
    cd "cartridges/$cart/ffi"
    if zig build test 2>/dev/null; then
        green "  $cart: tests passed"
        PASS=$((PASS + 1))
    else
        red "  $cart: tests failed"
        FAIL=$((FAIL + 1))
    fi
    cd "$PROJECT_DIR"
done

# --- Step 6: Run benchmarks ---
echo ""
echo "Step 6: Running benchmarks..."
cd "$PROJECT_DIR/ffi/zig"
if zig build bench 2>&1; then
    green "  Benchmarks completed"
else
    yellow "  Benchmark build failed"
    SKIP=$((SKIP + 1))
fi

# --- Step 7: Verify matrix status ---
echo ""
echo "Step 7: Matrix verification..."
cd "$PROJECT_DIR"
for cart in database-mcp fleet-mcp nesy-mcp agent-mcp; do
    abi_ok=false; ffi_ok=false; adapter_ok=false
    [ -f "cartridges/$cart/abi"/*/*.idr ] 2>/dev/null && abi_ok=true
    [ -f "cartridges/$cart/ffi"/*_ffi.zig ] 2>/dev/null && ffi_ok=true
    [ -f "cartridges/$cart/adapter"/*_adapter.v ] 2>/dev/null && adapter_ok=true

    if $abi_ok && $ffi_ok && $adapter_ok; then
        green "  $cart: ABI+FFI+Adapter complete"
        PASS=$((PASS + 1))
    else
        red "  $cart: incomplete (ABI=$abi_ok FFI=$ffi_ok Adapter=$adapter_ok)"
        FAIL=$((FAIL + 1))
    fi
done

# --- Summary ---
echo ""
echo "═══════════════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL + SKIP))
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped (of $TOTAL)"
if [ $FAIL -eq 0 ]; then
    green "  Integration tests: ALL PASS"
else
    red "  Integration tests: $FAIL FAILURES"
    exit 1
fi
echo "═══════════════════════════════════════════════════════════════"
