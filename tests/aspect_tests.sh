#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ Server — Aspect tests (cross-cutting concern validation).
#
# Validates architectural invariants that span the entire codebase:
#   1. Thread safety — all Zig FFI modules use Mutex protection
#   2. Formal verification safety — no believe_me or assert_total in Idris2
#   3. SPDX compliance — all source files have license headers
#   4. Cartridge completeness — all cartridges have ABI + FFI layers
#   5. Error handling — no panic/unreachable in production Zig code paths
#
# Usage:
#   bash tests/aspect_tests.sh
#
# Prerequisites:
#   - Run from the boj-server repository root

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
WARN=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

pass() {
    green "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    red "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

warn() {
    yellow "  WARN: $1"
    WARN=$((WARN + 1))
}

echo "═══════════════════════════════════════════════════════════════"
echo "  BoJ Server — Aspect Tests (Cross-Cutting Concerns)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Aspect 1: Thread Safety — Mutex in every Zig FFI module
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 1: Thread safety (Mutex protection)"

# Every .zig file in ffi/zig/src/ that has C-ABI exports (pub export fn)
# must also declare a Mutex for thread-safe access.
zig_ffi_dir="$PROJECT_DIR/ffi/zig/src"
aspect1_ok=true

for zigfile in "$zig_ffi_dir"/*.zig; do
    basename_zig=$(basename "$zigfile")

    # Skip test-only / bench-only files (no C-ABI exports)
    case "$basename_zig" in
        seams.zig|bench.zig|e2e_order.zig|readiness.zig)
            continue
            ;;
    esac

    has_export=$(grep -cP '(?:pub )?export fn' "$zigfile" 2>/dev/null || true)
    has_mutex=$(grep -c 'Mutex' "$zigfile" 2>/dev/null || true)

    if [[ "$has_export" -gt 0 && "$has_mutex" -eq 0 ]]; then
        fail "$basename_zig has $has_export C-ABI exports but no Mutex"
        aspect1_ok=false
    elif [[ "$has_export" -gt 0 ]]; then
        pass "$basename_zig: Mutex protected ($has_export exports)"
    fi
done

# Also check cartridge FFI modules
for cart_dir in "$PROJECT_DIR"/cartridges/*/ffi; do
    [ -d "$cart_dir" ] || continue
    cart_name=$(basename "$(dirname "$cart_dir")")

    # Find the main FFI .zig file
    ffi_zig=$(find "$cart_dir" -name '*_ffi.zig' -o -name 'main.zig' 2>/dev/null | head -1)
    if [[ -z "$ffi_zig" ]]; then
        # Check src/ subdirectory
        ffi_zig=$(find "$cart_dir/src" -name '*.zig' 2>/dev/null | head -1)
    fi

    if [[ -n "$ffi_zig" ]]; then
        has_export=$(grep -c 'pub export fn' "$ffi_zig" 2>/dev/null || true)
        has_mutex=$(grep -c 'Mutex' "$ffi_zig" 2>/dev/null || true)

        if [[ "$has_export" -gt 0 && "$has_mutex" -eq 0 ]]; then
            fail "$cart_name FFI: $has_export exports, no Mutex"
            aspect1_ok=false
        elif [[ "$has_export" -gt 0 ]]; then
            pass "$cart_name FFI: Mutex protected"
        fi
    fi
done
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Aspect 2: Formal Verification Safety — banned patterns in Idris2
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 2: Formal verification safety (Idris2)"

# believe_me — unsafe cast, bypasses type checker
believe_hits=$(grep -rn 'believe_me' "$PROJECT_DIR" --include='*.idr' \
    | grep -v '^\s*--' \
    | grep -v '^\s*|||' \
    | grep -v 'flags believe_me' \
    | grep -v 'Echidnabot' \
    || true)

if [[ -z "$believe_hits" ]]; then
    pass "No believe_me usage in Idris2 code"
else
    fail "believe_me found in Idris2 code:"
    echo "$believe_hits" | head -5
fi

# assert_total — bypasses totality checker
assert_hits=$(grep -rn 'assert_total' "$PROJECT_DIR" --include='*.idr' \
    | grep -v '^\s*--' \
    | grep -v '^\s*|||' \
    | grep -v 'flags assert_total' \
    | grep -v 'Echidnabot' \
    || true)

if [[ -z "$assert_hits" ]]; then
    pass "No assert_total usage in Idris2 code"
else
    fail "assert_total found in Idris2 code:"
    echo "$assert_hits" | head -5
fi

# Admitted — Coq/Lean hole, but check anyway
admitted_hits=$(grep -rn '\bAdmitted\b' "$PROJECT_DIR" --include='*.idr' \
    | grep -v '^\s*--' \
    | grep -v '^\s*|||' \
    || true)

if [[ -z "$admitted_hits" ]]; then
    pass "No Admitted in Idris2 code"
else
    fail "Admitted found in Idris2 code:"
    echo "$admitted_hits" | head -5
fi

# sorry — proof hole
sorry_hits=$(grep -rn '\bsorry\b' "$PROJECT_DIR" --include='*.idr' \
    | grep -v '^\s*--' \
    | grep -v '^\s*|||' \
    | grep -v 'Echidnabot' \
    | grep -v 'sorry)' \
    || true)

if [[ -z "$sorry_hits" ]]; then
    pass "No sorry proof holes in Idris2 code"
else
    fail "sorry found in Idris2 code:"
    echo "$sorry_hits" | head -5
fi

# unsafeCoerce — another unsafe cast pattern
unsafe_hits=$(grep -rn 'unsafeCoerce\|unsafePerformIO\|Obj\.magic' "$PROJECT_DIR" --include='*.idr' \
    | grep -v '^\s*--' \
    || true)

if [[ -z "$unsafe_hits" ]]; then
    pass "No unsafeCoerce/unsafePerformIO/Obj.magic in Idris2 code"
else
    fail "Unsafe patterns found in Idris2 code:"
    echo "$unsafe_hits" | head -5
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Aspect 3: SPDX Compliance — license headers on all source files
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 3: SPDX header compliance"

spdx_missing=0
spdx_checked=0

# Check Zig files
for zigfile in $(find "$PROJECT_DIR" -name '*.zig' -not -path '*/.zig-cache/*' -not -path '*/zig-cache/*' -not -path '*/zig-out/*' 2>/dev/null); do
    spdx_checked=$((spdx_checked + 1))
    if ! head -5 "$zigfile" | grep -q 'SPDX-License-Identifier'; then
        fail "Missing SPDX header: $(basename "$zigfile") ($(dirname "$zigfile" | sed "s|$PROJECT_DIR/||"))"
        spdx_missing=$((spdx_missing + 1))
    fi
done

# Check Idris2 files
for idrfile in $(find "$PROJECT_DIR" -name '*.idr' -not -path '*/build/*' 2>/dev/null); do
    spdx_checked=$((spdx_checked + 1))
    if ! head -5 "$idrfile" | grep -q 'SPDX-License-Identifier'; then
        fail "Missing SPDX header: $(basename "$idrfile") ($(dirname "$idrfile" | sed "s|$PROJECT_DIR/||"))"
        spdx_missing=$((spdx_missing + 1))
    fi
done

# Check shell scripts
for shfile in $(find "$PROJECT_DIR" -name '*.sh' -not -path '*/.machine_readable/scripts/*' 2>/dev/null); do
    spdx_checked=$((spdx_checked + 1))
    if ! head -5 "$shfile" | grep -q 'SPDX-License-Identifier'; then
        fail "Missing SPDX header: $(basename "$shfile") ($(dirname "$shfile" | sed "s|$PROJECT_DIR/||"))"
        spdx_missing=$((spdx_missing + 1))
    fi
done

# Check JavaScript files
for jsfile in $(find "$PROJECT_DIR" -name '*.js' -not -path '*/node_modules/*' 2>/dev/null); do
    spdx_checked=$((spdx_checked + 1))
    if ! head -5 "$jsfile" | grep -q 'SPDX-License-Identifier'; then
        fail "Missing SPDX header: $(basename "$jsfile") ($(dirname "$jsfile" | sed "s|$PROJECT_DIR/||"))"
        spdx_missing=$((spdx_missing + 1))
    fi
done

if [[ $spdx_missing -eq 0 ]]; then
    pass "All $spdx_checked source files have SPDX headers"
else
    red "  $spdx_missing/$spdx_checked files missing SPDX headers"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Aspect 4: Cartridge Completeness — ABI + FFI layers
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 4: Cartridge layer completeness (ABI + FFI)"

incomplete=0
complete=0

for cart_dir in "$PROJECT_DIR"/cartridges/*/; do
    cart_name=$(basename "$cart_dir")
    has_abi=false; has_ffi=false

    [ -d "$cart_dir/abi" ] && has_abi=true
    [ -d "$cart_dir/ffi" ] && has_ffi=true

    if $has_abi && $has_ffi; then
        complete=$((complete + 1))
    else
        fail "$cart_name: incomplete layers (ABI=$has_abi FFI=$has_ffi)"
        incomplete=$((incomplete + 1))
    fi
done

if [[ $incomplete -eq 0 ]]; then
    pass "All $complete cartridges have ABI + FFI layers"
else
    red "  $incomplete cartridges are incomplete"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Aspect 5: Error handling — no unreachable in production Zig exports
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 5: Error handling (no bare unreachable in Zig exports)"

# Check for bare `unreachable` in production code paths (not test files)
unreachable_count=0
for zigfile in "$zig_ffi_dir"/*.zig; do
    basename_zig=$(basename "$zigfile")
    case "$basename_zig" in
        seams.zig|bench.zig|e2e_order.zig|readiness.zig)
            continue
            ;;
    esac

    # Count bare unreachable (not in test blocks, not in comments)
    hits=$(grep -n '\bunreachable\b' "$zigfile" 2>/dev/null \
        | grep -v '//' \
        | grep -v 'test "' \
        || true)

    if [[ -n "$hits" ]]; then
        warn "$basename_zig has unreachable statements (review for safety):"
        echo "$hits" | head -3 | sed 's/^/    /'
        unreachable_count=$((unreachable_count + 1))
    fi
done

if [[ $unreachable_count -eq 0 ]]; then
    pass "No bare unreachable in production Zig FFI modules"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo "═══════════════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL + WARN))
echo "  Results: $PASS passed, $FAIL failed, $WARN warnings (of $TOTAL)"
if [ $FAIL -eq 0 ]; then
    green "  Aspect Tests: ALL PASS"
else
    red "  Aspect Tests: $FAIL FAILURES"
fi
echo "═══════════════════════════════════════════════════════════════"

exit "$FAIL"
