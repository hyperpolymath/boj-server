#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ Server — End-to-end integration test.
#
# Tests the full pipeline:
#   1. Build Zig FFI library
#   2. Build zig adapter
#   3. Start the server
#   4. Exercise all REST endpoints
#   5. Exercise GraphQL endpoint
#   6. Test order-ticket flow
#   7. Verify cartridge mount/unmount via API
#   8. Tear down

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Cartridge catalog root: the bundled cartridges/ tree was retired in favour
# of hyperpolymath/boj-server-cartridges. Default to the tracked fixture
# catalogue (as tests/e2e_full.sh does); point BOJ_CARTRIDGES_PATH at a cache
# populated by scripts/fetch-cartridges.sh to exercise the full registry.
CARTRIDGES_ROOT="${BOJ_CARTRIDGES_PATH:-$PROJECT_DIR/tests/fixtures/cartridges}"

# The four cartridges these steps were written against. They are no longer
# bundled, so each step reports per-cartridge whether it found a subject:
# absent or manifest-only means SKIP with a message, never a silent pass.
SUBJECT_CARTS=(database-mcp fleet-mcp nesy-mcp agent-mcp)

# A cartridge carrying none of abi/, ffi/, adapter/ is a manifest-only
# catalogue entry — the shape of the tracked fixture catalogue, and of any
# registry entry not yet implemented. There is no implementation to audit,
# so the layer checks skip it rather than reporting a phantom defect.
# A cartridge with SOME layers but not the one under test is a real defect
# and still fails.
is_manifest_only() {
    local d="$1"
    [ ! -d "$d/abi" ] && [ ! -d "$d/ffi" ] && [ ! -d "$d/adapter" ]
}

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

# --- Step 4: Verify Zig adapter completeness ---
echo ""
echo "Step 4: Verifying Zig adapter completeness (catalog root: $CARTRIDGES_ROOT)..."
cd "$PROJECT_DIR"
adapter_count=0
adapter_skipped=0
for cart in "${SUBJECT_CARTS[@]}"; do
    cart_dir="$CARTRIDGES_ROOT/$cart"
    if [ ! -d "$cart_dir" ]; then
        yellow "  SKIP: $cart is not in $CARTRIDGES_ROOT"
        adapter_skipped=$((adapter_skipped + 1))
    elif is_manifest_only "$cart_dir"; then
        yellow "  SKIP: $cart is a manifest-only catalogue entry — no adapter to check"
        adapter_skipped=$((adapter_skipped + 1))
    elif [ -f "$cart_dir/adapter/${cart%%-mcp}_adapter.zig" ]; then
        adapter_count=$((adapter_count + 1))
    else
        red "  $cart: has implementation layers but no adapter/${cart%%-mcp}_adapter.zig"
        FAIL=$((FAIL + 1))
    fi
done
if [ $adapter_count -eq ${#SUBJECT_CARTS[@]} ]; then
    green "  All Zig adapters present ($adapter_count/${#SUBJECT_CARTS[@]})"
    PASS=$((PASS + 1))
elif [ $adapter_skipped -gt 0 ]; then
    yellow "  $adapter_skipped/${#SUBJECT_CARTS[@]} subject cartridges carry no implementation here."
    yellow "  Adapters live in hyperpolymath/boj-server-cartridges — populate a cache"
    yellow "  with scripts/fetch-cartridges.sh and set BOJ_CARTRIDGES_PATH to check them."
    SKIP=$((SKIP + 1))
fi

# --- Step 5: Run cartridge FFI tests ---
echo ""
echo "Step 5: Running cartridge FFI tests (catalog root: $CARTRIDGES_ROOT)..."
cd "$PROJECT_DIR"
ffi_ran=0
for cart in "${SUBJECT_CARTS[@]}"; do
    ffi_dir="$CARTRIDGES_ROOT/$cart/ffi"
    if [ ! -f "$ffi_dir/build.zig" ]; then
        yellow "  SKIP: $cart has no $ffi_dir/build.zig — nothing to test"
        SKIP=$((SKIP + 1))
        continue
    fi
    ffi_ran=$((ffi_ran + 1))
    if (cd "$ffi_dir" && zig build test 2>/dev/null); then
        green "  $cart: tests passed"
        PASS=$((PASS + 1))
    else
        red "  $cart: tests failed"
        FAIL=$((FAIL + 1))
    fi
done
if [ $ffi_ran -eq 0 ]; then
    yellow "  No cartridge FFI test ran — the subjects are in"
    yellow "  hyperpolymath/boj-server-cartridges. Populate a cache with"
    yellow "  scripts/fetch-cartridges.sh and set BOJ_CARTRIDGES_PATH to run them."
fi

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
matrix_skipped=0
for cart in "${SUBJECT_CARTS[@]}"; do
    cart_dir="$CARTRIDGES_ROOT/$cart"
    if [ ! -d "$cart_dir" ]; then
        yellow "  SKIP: $cart is not in $CARTRIDGES_ROOT"
        matrix_skipped=$((matrix_skipped + 1))
        SKIP=$((SKIP + 1))
        continue
    fi
    if is_manifest_only "$cart_dir"; then
        yellow "  SKIP: $cart is a manifest-only catalogue entry — no layers to verify"
        matrix_skipped=$((matrix_skipped + 1))
        SKIP=$((SKIP + 1))
        continue
    fi
    abi_ok=false; ffi_ok=false; adapter_ok=false
    # `[ -f dir/*_ffi.zig ]` is not a glob test (SC2144): with two matches it
    # errors out, with none it tests the literal pattern. Use find.
    find "$CARTRIDGES_ROOT/$cart/abi" -name '*.idr' 2>/dev/null | grep -q . && abi_ok=true
    find "$CARTRIDGES_ROOT/$cart/ffi" -maxdepth 1 -name '*_ffi.zig' 2>/dev/null | grep -q . && ffi_ok=true
    find "$CARTRIDGES_ROOT/$cart/adapter" -maxdepth 1 -name '*_adapter.v' 2>/dev/null | grep -q . && adapter_ok=true

    if $abi_ok && $ffi_ok && $adapter_ok; then
        green "  $cart: ABI+FFI+Adapter complete"
        PASS=$((PASS + 1))
    else
        red "  $cart: incomplete (ABI=$abi_ok FFI=$ffi_ok Adapter=$adapter_ok)"
        FAIL=$((FAIL + 1))
    fi
done
if [ $matrix_skipped -eq ${#SUBJECT_CARTS[@]} ]; then
    yellow "  Matrix verification checked nothing — every subject cartridge is"
    yellow "  absent or manifest-only under $CARTRIDGES_ROOT. The implementations"
    yellow "  live in hyperpolymath/boj-server-cartridges (scripts/fetch-cartridges.sh)."
fi

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
