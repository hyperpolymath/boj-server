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

# Cartridge catalog root: the bundled cartridges/ tree was retired in favour
# of hyperpolymath/boj-server-cartridges. Default to the tracked fixture
# catalogue (as tests/e2e_full.sh does); point BOJ_CARTRIDGES_PATH at a cache
# populated by scripts/fetch-cartridges.sh to audit the full registry.
CARTRIDGES_ROOT="${BOJ_CARTRIDGES_PATH:-$PROJECT_DIR/tests/fixtures/cartridges}"

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

# Detect file-scope mutable globals: lines starting with optional `pub`
# then `var` then identifier. Stack-local `var` inside a function body
# is fine — it's per-call, not shared. We anchor at the start of the
# line to exclude function-body `var`. Purely-functional FFI (e.g.
# burble_admin_ffi.zig — table-lookup + arithmetic, zero globals) does
# not need a Mutex.
has_file_scope_globals() {
    grep -cE '^(pub )?var [A-Za-z_]' "$1" 2>/dev/null || true
}

for zigfile in "$zig_ffi_dir"/*.zig; do
    basename_zig=$(basename "$zigfile")

    # Skip test-only / bench-only files (no C-ABI exports)
    case "$basename_zig" in
        seams.zig|bench.zig|e2e_order.zig|readiness.zig)
            continue
            ;;
    esac

    has_export=$(grep -cP '(?:pub )?export fn' "$zigfile" 2>/dev/null || true)
    has_globals=$(has_file_scope_globals "$zigfile")
    has_mutex=$(grep -c 'Mutex' "$zigfile" 2>/dev/null || true)

    if [[ "$has_export" -gt 0 && "$has_globals" -gt 0 && "$has_mutex" -eq 0 ]]; then
        fail "$basename_zig has $has_export C-ABI exports and $has_globals globals but no Mutex"
        aspect1_ok=false
    elif [[ "$has_export" -gt 0 && "$has_mutex" -gt 0 ]]; then
        pass "$basename_zig: Mutex protected ($has_export exports, $has_globals globals)"
    elif [[ "$has_export" -gt 0 ]]; then
        pass "$basename_zig: purely functional ($has_export exports, no globals)"
    fi
done

# Also check cartridge FFI modules in the catalog root
cart_ffi_seen=0
for cart_dir in "$CARTRIDGES_ROOT"/*/ffi; do
    [ -d "$cart_dir" ] || continue
    cart_ffi_seen=$((cart_ffi_seen + 1))
    cart_name=$(basename "$(dirname "$cart_dir")")

    # Find the main FFI .zig file
    ffi_zig=$(find "$cart_dir" -name '*_ffi.zig' -o -name 'main.zig' 2>/dev/null | head -1)
    if [[ -z "$ffi_zig" ]]; then
        # Check src/ subdirectory
        ffi_zig=$(find "$cart_dir/src" -name '*.zig' 2>/dev/null | head -1)
    fi

    if [[ -n "$ffi_zig" ]]; then
        has_export=$(grep -c 'pub export fn' "$ffi_zig" 2>/dev/null || true)
        has_globals=$(has_file_scope_globals "$ffi_zig")
        has_mutex=$(grep -c 'Mutex' "$ffi_zig" 2>/dev/null || true)

        if [[ "$has_export" -gt 0 && "$has_globals" -gt 0 && "$has_mutex" -eq 0 ]]; then
            fail "$cart_name FFI: $has_export exports + $has_globals globals, no Mutex"
            aspect1_ok=false
        elif [[ "$has_export" -gt 0 && "$has_mutex" -gt 0 ]]; then
            pass "$cart_name FFI: Mutex protected"
        elif [[ "$has_export" -gt 0 ]]; then
            pass "$cart_name FFI: purely functional ($has_export exports, no globals)"
        fi
    fi
done
if [[ "$cart_ffi_seen" -eq 0 ]]; then
    warn "no cartridge FFI under $CARTRIDGES_ROOT — checked the core FFI only"
    warn "  populate a cache with scripts/fetch-cartridges.sh, then set BOJ_CARTRIDGES_PATH"
else
    echo "  (audited $cart_ffi_seen cartridge FFI dir(s) under $CARTRIDGES_ROOT)"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════
# Aspect 2: Formal Verification Safety — banned patterns in Idris2
# ═══════════════════════════════════════════════════════════════════════
bold "Aspect 2: Formal verification safety (Idris2)"

# Documented exemptions for proof-bearing files that intentionally
# carry class-J axioms (irreducible primitive escapes — see
# docs/PROOF-NEEDS.md and ADR-008). Adding to this list requires an
# ADR or a referenced design memo.
PROOF_EXEMPT='src/abi/Boj/SafetyLemmas\.idr'

# Strip Idris2 comments from `grep -rn` output before pattern checks.
#
# grep output is `path:lineno:content` — line-anchored filters (`^\s*--`,
# `^\s*|||`) never match because the path prefix comes first. We handle
# three comment shapes that produce false-positive matches:
#
#   1. line-start `--`  comment            → filtered by `:[[:space:]]*--`
#   2. line-start `|||` doc-comment        → filtered by `:[[:space:]]*\|\|\|`
#   3. trailing  `… -- … <pattern>`        → filtered per-pattern (caller-supplied)
#
# Shape (3) requires the caller's pattern as context, so we accept it
# as $1 and tack on a `:.*--.*<pat>` filter.
strip_comments_and_docstrings() {
    local pat="$1"
    grep -v ':[[:space:]]*--' \
        | grep -v ':[[:space:]]*|||' \
        | grep -vE ":.*--.*${pat}"
}

# believe_me — unsafe cast, bypasses type checker
believe_hits=$(grep -rn 'believe_me' "$PROJECT_DIR" --include='*.idr' \
    | strip_comments_and_docstrings 'believe_me' \
    | grep -vE "$PROOF_EXEMPT" \
    | grep -v 'flags believe_me' \
    | grep -v 'Echidnabot' \
    || true)

if [[ -z "$believe_hits" ]]; then
    pass "No believe_me usage in Idris2 code (excluding documented class-J axioms)"
else
    fail "believe_me found in Idris2 code:"
    echo "$believe_hits" | head -5
fi

# assert_total — bypasses totality checker
assert_hits=$(grep -rn 'assert_total' "$PROJECT_DIR" --include='*.idr' \
    | strip_comments_and_docstrings 'assert_total' \
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
    | strip_comments_and_docstrings 'Admitted' \
    || true)

if [[ -z "$admitted_hits" ]]; then
    pass "No Admitted in Idris2 code"
else
    fail "Admitted found in Idris2 code:"
    echo "$admitted_hits" | head -5
fi

# sorry — proof hole
sorry_hits=$(grep -rn '\bsorry\b' "$PROJECT_DIR" --include='*.idr' \
    | strip_comments_and_docstrings 'sorry' \
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
    | grep -v ':[[:space:]]*--' \
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

# A cartridge's `cartridge.json` may carry an explicit `status` field:
#
#   "status": "complete"     — must have abi/ AND ffi/ (default)
#   "status": "stub"         — manifest-only, abi/ + ffi/ not yet written
#   "status": "ffi_only"     — observability / glue cartridge that
#                              intentionally carries no formal ABI proof
#                              (e.g., boj-health monitoring code, MCP
#                              adapters bridging external APIs)
#
# The catalogue that replaced the bundled tree spells the same two
# exemptions differently, so both vocabularies are accepted:
#
#   "status": "catalogued"   — manifest-only; identical rule to `stub`
#   "status": "ready"        — built and advertised; identical rule to
#                              `ffi_only` (FFI present, ABI optional)
#
# `stub`/`catalogued` and `ffi_only`/`ready` are passed but counted in a
# separate informational tally so they remain visible. The
# default-when-absent is `complete` (strict). Adding a new exemption
# requires editing cartridge.json with a stated rationale and is
# reviewable in PR diff.
read_cartridge_status() {
    local manifest="$1"
    [ -f "$manifest" ] || { echo "complete"; return; }
    # Cheap JSON extraction without jq dependency: grep + sed.
    local s
    s=$(grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]+"' "$manifest" \
        | head -1 \
        | sed -E 's/.*"status"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    [ -z "$s" ] && s="complete"
    echo "$s"
}

incomplete=0
complete=0
stubs=0
ffi_only=0

# The bundled cartridges/ tree was retired (canonical source:
# hyperpolymath/boj-server-cartridges, which carries its own completeness
# gates). Audit whatever catalog root is configured; an empty root means
# this aspect verified nothing and must say so, never report success.
audited=0
shopt -s nullglob

for cart_dir in "$CARTRIDGES_ROOT"/*/; do
    cart_name=$(basename "$cart_dir")
    audited=$((audited + 1))
    has_abi=false; has_ffi=false

    [ -d "$cart_dir/abi" ] && has_abi=true
    [ -d "$cart_dir/ffi" ] && has_ffi=true

    status=$(read_cartridge_status "$cart_dir/cartridge.json")

    case "$status" in
        stub|catalogued)
            # Manifest-only design — both layers absent is the expected shape.
            if ! $has_abi && ! $has_ffi; then
                pass "$cart_name: $status (manifest-only, by design)"
                stubs=$((stubs + 1))
            else
                fail "$cart_name: marked $status but has partial implementation (ABI=$has_abi FFI=$has_ffi) — promote to ffi_only/ready or complete"
                incomplete=$((incomplete + 1))
            fi
            ;;
        ffi_only|ready)
            if $has_ffi && ! $has_abi; then
                pass "$cart_name: $status (FFI present, no formal ABI by design)"
                ffi_only=$((ffi_only + 1))
            elif $has_ffi && $has_abi; then
                # If ABI got added later, the manifest is stale. Pass but warn.
                pass "$cart_name: $status (manifest stale — both layers present, complete)"
                complete=$((complete + 1))
            else
                fail "$cart_name: marked $status but FFI missing"
                incomplete=$((incomplete + 1))
            fi
            ;;
        complete|*)
            if $has_abi && $has_ffi; then
                complete=$((complete + 1))
            else
                fail "$cart_name: incomplete layers (ABI=$has_abi FFI=$has_ffi)"
                incomplete=$((incomplete + 1))
            fi
            ;;
    esac
done
shopt -u nullglob

if [[ $audited -eq 0 ]]; then
    # An empty catalog root proves nothing. Say so; do not count a PASS.
    fail "no cartridges found under $CARTRIDGES_ROOT — completeness verified nothing"
    yellow "  populate a cache with scripts/fetch-cartridges.sh, then set BOJ_CARTRIDGES_PATH"
elif [[ $incomplete -eq 0 ]]; then
    pass "All $audited cartridges under $CARTRIDGES_ROOT accounted for ($complete complete, $stubs manifest-only, $ffi_only ffi-only)"
else
    red "  $incomplete of $audited cartridges under $CARTRIDGES_ROOT are incomplete"
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
