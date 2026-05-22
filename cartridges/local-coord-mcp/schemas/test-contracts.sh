#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# test-contracts.sh — Smoke-test the Nickel contracts in
# coord-messages-contracts.ncl. Each case either passes (envelope
# accepted by validator) or fails (validator rejects with a specific
# contract violation).
#
# Usage: bash test-contracts.sh

set -u
cd "$(dirname "$0")"

PASS=0
FAIL=0
EXPECTED_FAILS=0

# Run Nickel with an inline envelope piped through the validator.
# Exit 0 = accepted; non-zero = contract violation.
run_case() {
    local name="$1"
    local envelope="$2"
    local expect="$3" # "pass" or "fail"

    # Create temp file in schemas/ so relative import works.
    local out
    local tmp="./_test_case_$$.ncl"
    cat > "$tmp" <<NICKEL_EOF
let c = import "coord-messages-contracts.ncl" in
let e = $envelope in
c.validate e
NICKEL_EOF
    out=$(nickel eval "$tmp" 2>&1)
    local rc=$?
    rm -f "$tmp"

    if [ "$expect" = "pass" ]; then
        if [ $rc -eq 0 ]; then
            echo "  PASS: $name"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $name (expected accept, got reject)"
            echo "        $out" | head -3
            FAIL=$((FAIL + 1))
        fi
    else
        if [ $rc -ne 0 ]; then
            echo "  PASS: $name (expected reject — good)"
            EXPECTED_FAILS=$((EXPECTED_FAILS + 1))
        else
            echo "  FAIL: $name (expected reject, got accept)"
            FAIL=$((FAIL + 1))
        fi
    fi
}

echo "=== Nickel contract tests ==="

# ── Valid cases ────────────────────────────────────────────────

run_case "tier 0 status envelope" \
'{
    version = 1,
    msg_id = "abcdef012345",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "gemini-b2c1",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "status",
    risk_tier = 0,
    payload = { status = "ok" },
}' \
"pass"

run_case "tier 2 claim with context_fetch_id" \
'{
    version = 1,
    msg_id = "abcdef012346",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "claim",
    risk_tier = 2,
    payload = { task = "audit-X", scope = "repo" },
    context_fetch_id = "ctx-abc123",
}' \
"pass"

# ── Rejections ─────────────────────────────────────────────────

run_case "tier 2 claim WITHOUT context_fetch_id (TierContextGate)" \
'{
    version = 1,
    msg_id = "abcdef012347",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "claim",
    risk_tier = 2,
    payload = { task = "audit-X", scope = "repo" },
}' \
"fail"

run_case "tier 3 from apprentice WITHOUT attestation (TierAttestationGate) — exercises DD-32 'supervised' alias" \
'{
    version = 1,
    msg_id = "abcdef012348",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "gemini-b2c1",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "gated_op",
    risk_tier = 3,
    payload = { action = "push" },
    context_fetch_id = "ctx-abc123",
    _meta = { sender_role = "supervised" },
}' \
"fail"

run_case "urgent_direct from apprentice (UrgentDirectRestriction) — exercises DD-32 'supervised' alias" \
'{
    version = 1,
    msg_id = "abcdef012349",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "gemini-b2c1",
    recipient = "claude-7f3a",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "clarify",
    risk_tier = 0,
    payload = { question = "hey" },
    urgent_direct = true,
    _meta = { sender_role = "supervised" },
}' \
"fail"

run_case "status declared as tier 3 WITHOUT tier_override_reason (TierOverrideJustification)" \
'{
    version = 1,
    msg_id = "abcdef01234a",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "gemini-b2c1",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "status",
    risk_tier = 3,
    payload = { status = "ok" },
    context_fetch_id = "ctx-abc",
}' \
"fail"

# ── Task #15 fields ────────────────────────────────────────────

run_case "claim with valid sender_confidence + dispatch_preference + task_difficulty" \
'{
    version = 1,
    msg_id = "abcdef01234b",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "claim",
    risk_tier = 2,
    payload = { task = "proof-audit" },
    context_fetch_id = "ctx-xyz",
    sender_confidence = 0.75,
    dispatch_preference = "deliberate",
    task_difficulty = "challenging",
}' \
"pass"

run_case "sender_confidence outside 0..1 (ConfidenceShape)" \
'{
    version = 1,
    msg_id = "abcdef01234c",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "status",
    risk_tier = 0,
    payload = { status = "ok" },
    sender_confidence = 1.5,
}' \
"fail"

run_case "unknown dispatch_preference string (DispatchPrefShape)" \
'{
    version = 1,
    msg_id = "abcdef01234d",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "claim",
    risk_tier = 2,
    payload = { task = "x" },
    context_fetch_id = "ctx",
    dispatch_preference = "yolo",
}' \
"fail"

run_case "unknown task_difficulty string (TaskDifficultyShape)" \
'{
    version = 1,
    msg_id = "abcdef01234e",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "claim",
    risk_tier = 2,
    payload = { task = "x" },
    context_fetch_id = "ctx",
    task_difficulty = "spicy",
}' \
"fail"

# ── Task #36 — difficulty_hint ────────────────────────────────

run_case "envelope with difficulty_hint=high (DifficultyHintValid)" \
'{
    version = 1,
    msg_id = "abcdef01234f",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "claim",
    risk_tier = 2,
    payload = { task = "tricky-proof" },
    context_fetch_id = "ctx",
    difficulty_hint = "high",
}' \
"pass"

run_case "unknown difficulty_hint string (DifficultyHintValid)" \
'{
    version = 1,
    msg_id = "abcdef012350",
    prev_msg_hash = "0000000000000000000000000000000000000000000000000000000000000000",
    sender = "claude-7f3a",
    recipient = "*",
    timestamp = "2026-04-20T10:00:00Z",
    op_kind = "status",
    risk_tier = 0,
    payload = { status = "ok" },
    difficulty_hint = "impossible",
}' \
"fail"

echo
echo "=== Summary ==="
echo "Accepted (pass expected): $PASS"
echo "Rejected (fail expected): $EXPECTED_FAILS"
echo "Unexpected:               $FAIL"

if [ $FAIL -eq 0 ]; then
    exit 0
else
    exit 1
fi
