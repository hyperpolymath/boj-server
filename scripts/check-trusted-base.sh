#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# check-trusted-base.sh — enforce the estate trusted-base reduction policy
# (hyperpolymath/standards#203, enforcement #211) for boj-server.
#
# The policy sanctions EXACTLY the 4 class-(J) axioms isolated in
# src/abi/Boj/SafetyLemmas.idr — opaque Char/String primitives that have no
# in-language induction principle in Idris2 0.8.0, externally validated by the
# backend-assurance harness (docs/backend-assurance/). Every other proof in the
# tree must be genuinely constructive.
#
# This script is referenced by PROOF-NEEDS.md and docs/proof-debt.md as the
# machine-checked index gate. It fails on:
#   * any believe_me / assert_total / assert_smaller / idris_crash outside the
#     sanctioned axiom module, and
#   * any drift in the audited axiom count (keep the docs in sync if it changes).
set -euo pipefail
cd "$(dirname "$0")/.."

AXIOM_FILE="src/abi/Boj/SafetyLemmas.idr"
# 4 since charEqSym was discharged to a constructive theorem (was 5); the
# survivors are charEqSound + the three String-primitive length axioms.
EXPECTED_AXIOMS=4

echo "==> Scanning for unsound constructs outside ${AXIOM_FILE}..."
FOUND=$(grep -rn 'believe_me\|assert_total\|assert_smaller\|idris_crash' \
        --include='*.idr' src/ cartridges/ verification/ 2>/dev/null \
    | grep -v -- '--.*believe_me'   | grep -v '|||.*believe_me' \
    | grep -v -- '--.*assert_'      | grep -v '|||.*assert_' \
    | grep -v -- '--.*idris_crash'  | grep -v '|||.*idris_crash' \
    | grep -v -- '--.*Admitted'     | grep -v '|||.*Admitted' \
    | grep -v -- '--.*sorry'        | grep -v '|||.*sorry' \
    | grep -v "^${AXIOM_FILE}:" || true)
if [ -n "$FOUND" ]; then
    echo "CRITICAL: undocumented unsound constructs found outside ${AXIOM_FILE}:"
    echo "$FOUND"
    echo ""
    echo "Each must be either made constructive or, if genuinely unavoidable,"
    echo "moved into ${AXIOM_FILE} and documented in PROOF-NEEDS.md + docs/proof-debt.md."
    exit 1
fi

AXIOM_COUNT=$(grep -c 'believe_me ()' "$AXIOM_FILE" 2>/dev/null || true)
if [ "$AXIOM_COUNT" != "$EXPECTED_AXIOMS" ]; then
    echo "CRITICAL: expected exactly ${EXPECTED_AXIOMS} sanctioned class-(J) axioms in"
    echo "${AXIOM_FILE}, found ${AXIOM_COUNT}."
    echo "If this change is intentional, update EXPECTED_AXIOMS here and sync"
    echo "PROOF-NEEDS.md + docs/proof-debt.md."
    exit 1
fi

echo "OK: no undocumented unsound constructs; ${AXIOM_COUNT} sanctioned class-(J) axioms (all in ${AXIOM_FILE})."
