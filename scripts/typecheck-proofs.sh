#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# typecheck-proofs.sh — type-check EVERY Idris2 proof in the repo under the
# pinned toolchain (Idris2 0.8.0, see .tool-versions).
#
# This is the gate that was missing. CI's abi-drift.yml only runs iseriser's
# structural manifest check, and the Justfile's old `typecheck` recipe covered
# just 5 of ~50 cartridge ABIs — so the rest drifted into non-compiling states
# undetected. This script type-checks:
#   * the core ABI package (src/abi/boj.ipkg), and
#   * every cartridge ABI (its .ipkg if present, else each .idr individually).
#
# Exit non-zero if anything fails to type-check.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
pass=0

check_ipkg() { # dir ipkg
    if ( cd "$1" && idris2 --typecheck "$2" >/dev/null 2>&1 ); then
        pass=$((pass + 1))
    else
        echo "  FAIL  $1/$2"
        ( cd "$1" && idris2 --typecheck "$2" 2>&1 | grep -A2 -iE '^Error' | head -6 | sed 's/^/        /' )
        fail=$((fail + 1))
    fi
}
check_idr() { # dir relfile
    if ( cd "$1" && idris2 --check "$2" >/dev/null 2>&1 ); then
        pass=$((pass + 1))
    else
        echo "  FAIL  $1/$2"
        ( cd "$1" && idris2 --check "$2" 2>&1 | grep -A2 -iE '^Error' | head -6 | sed 's/^/        /' )
        fail=$((fail + 1))
    fi
}

echo "==> Core ABI package (src/abi/boj.ipkg)"
check_ipkg src/abi boj.ipkg

echo "==> Cartridge ABIs"
for d in cartridges/*/abi; do
    [ -d "$d" ] || continue
    ipkg=$(ls "$d"/*.ipkg 2>/dev/null | head -1)
    if [ -n "$ipkg" ]; then
        check_ipkg "$d" "$(basename "$ipkg")"
    else
        while IFS= read -r f; do
            check_idr "$d" "${f#"$d"/}"
        done < <(find "$d" -name '*.idr')
    fi
done

echo "────────────────────────────────────────"
echo "Proof type-check: PASS=${pass} FAIL=${fail}"
[ "$fail" -eq 0 ] || { echo "PROOF TYPECHECK FAILED"; exit 1; }
echo "All proofs type-check under the pinned toolchain."
