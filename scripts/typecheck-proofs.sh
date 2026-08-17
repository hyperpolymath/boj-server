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
cd "$(dirname "$0")/.." || exit 1

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

# Cartridge ABIs used to be walked here (cartridges/*/abi). That tree was
# retired — the cartridges now live in hyperpolymath/boj-server-cartridges,
# which type-checks its own 126 abi/ dirs in its own proofs gate. The loop is
# deliberately NOT replaced with one over a fetched cache: a gate that only
# checks what happens to be on disk is not a gate.

echo "────────────────────────────────────────"
echo "Proof type-check: PASS=${pass} FAIL=${fail}"
[ "$fail" -eq 0 ] || { echo "PROOF TYPECHECK FAILED"; exit 1; }

# Vacuous-pass guard (ported from boj-server-cartridges' twin of this script).
# PASS=0/FAIL=0 means nothing was found to check — a moved directory, a bad
# checkout, or a refactor that renames src/abi. Without this the gate reports
# success having verified NOTHING, which is exactly the failure mode this
# script exists to prevent. A repo with zero proofs is not a passing repo;
# it is a broken gate.
if [ "$pass" -eq 0 ]; then
    echo "PROOF TYPECHECK FAILED: no proofs were found to check." >&2
    echo "  Expected the core ABI package at src/abi/boj.ipkg." >&2
    echo "  A green run with zero proofs verified would be a false assurance." >&2
    exit 1
fi

echo "All proofs type-check under the pinned toolchain."
