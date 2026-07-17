#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Integration test for bug-filing-mcp cartridge.
# This cartridge is a thin HTTP client over the feedback-o-tron engine's
# localhost intake, so the wire it owns is tested directly against the
# backend. Skips (exit 0) when the engine is not running.

set -euo pipefail

BACKEND_URL="${BUG_FILING_BACKEND_URL:-http://127.0.0.1:7722}"
PASS=0
FAIL=0

if ! curl -sf "${BACKEND_URL}/health" > /dev/null 2>&1; then
  echo "SKIP (engine not running — start feedback-o-tron with FEEDBACK_A_TRON_HTTP=1)"
  exit 0
fi

check() {
  local desc="$1" path="$2" payload="$3" expect="$4"
  local response
  response=$(curl -s -X POST "${BACKEND_URL}${path}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>/dev/null || echo '{"error":"connection_failed"}')

  if echo "$response" | grep -q "$expect"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected '$expect' in response)"
    echo "  Got: $response"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== bug-filing-mcp integration tests (backend: ${BACKEND_URL}) ==="
echo ""

health_response=$(curl -s "${BACKEND_URL}/health" 2>/dev/null || echo '{"error":"connection_failed"}')
if echo "$health_response" | grep -q '"status":"ok"'; then
  echo "PASS: health reports ok"
  PASS=$((PASS + 1))
else
  echo "FAIL: health reports ok"
  echo "  Got: $health_response"
  FAIL=$((FAIL + 1))
fi

check "submit_feedback: dry_run previews without filing" \
  "/api/v1/submit_feedback" \
  '{"title":"integration test","body":"dry run only","repo":"example/example","dry_run":true}' \
  "dry_run"

check "submit_feedback: missing fields rejected" \
  "/api/v1/submit_feedback" '{}' "missing_required_fields"

check "research_feedback: missing fields rejected" \
  "/api/v1/research_feedback" '{}' "missing_required_fields"

check "research_feedback: returns forge + local + templates sections" \
  "/api/v1/research_feedback" \
  '{"repo":"example/example","title":"integration probe"}' \
  '"local"'

check "synthesize_feedback: missing fields rejected" \
  "/api/v1/synthesize_feedback" '{}' "missing_required_fields"

check "synthesize_feedback: zero-signal hostility is rejected with a reason" \
  "/api/v1/synthesize_feedback" \
  '{"raw_feedback":"you all suck, worst tool ever","repo":"example/example"}' \
  '"rejected":true'

check "synthesize_feedback: real bug text yields a draft" \
  "/api/v1/synthesize_feedback" \
  '{"raw_feedback":"crashes with ** (RuntimeError) boom when saving","repo":"example/example"}' \
  '"draft"'

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
exit $FAIL
