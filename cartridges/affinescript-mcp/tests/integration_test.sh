#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Integration test for affinescript-mcp cartridge.
# Tests MCP tool invocations via the BoJ server REST API.

set -euo pipefail

BOJ_URL="${BOJ_URL:-http://localhost:7700}"
PASS=0
FAIL=0

check() {
  local desc="$1" tool="$2" args="$3" expect="$4"
  local response
  response=$(curl -s -X POST "${BOJ_URL}/mcp/affinescript-mcp" \
    -H "Content-Type: application/json" \
    -d "{\"tool\": \"${tool}\", \"args\": ${args}}" 2>/dev/null || echo '{"error":"connection_failed"}')

  if echo "$response" | grep -q "$expect"; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected '$expect' in response)"
    echo "  Got: $response"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== affinescript-mcp integration tests ==="
echo ""

# Syntax reference (pure lookup — no compiler needed)
check "syntax_ref: fn keyword" \
  "affinescript_syntax_ref" \
  '{"construct": "fn"}' \
  "Function definition"

check "syntax_ref: linear keyword" \
  "affinescript_syntax_ref" \
  '{"construct": "linear"}' \
  "Linear type qualifier"

check "syntax_ref: unknown keyword" \
  "affinescript_syntax_ref" \
  '{"construct": "foobar"}' \
  "Unknown construct"

# Error explanation (pure lookup)
check "explain_error: E2001 use after move" \
  "affinescript_explain_error" \
  '{"code": "E2001"}' \
  "Use after move"

check "explain_error: unknown code" \
  "affinescript_explain_error" \
  '{"code": "E9999"}' \
  "Unknown error code"

# Stdlib search (pure lookup)
check "stdlib: search for Option" \
  "affinescript_stdlib" \
  '{"query": "Option"}' \
  "Optional value"

check "stdlib: search for IO effect" \
  "affinescript_stdlib" \
  '{"query": "IO"}' \
  "Input/output"

# Format (pure — no compiler needed)
check "format: basic indentation" \
  "affinescript_format" \
  '{"source": "fn main() {\nlet x = 1\n}"}' \
  "formatted"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
exit $FAIL
