#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Quick benchmark for affinescript-mcp cartridge.
# Measures latency for pure lookup tools (no compiler dependency).

set -euo pipefail

BOJ_URL="${BOJ_URL:-http://localhost:7700}"
ITERATIONS=100

echo "=== affinescript-mcp quick benchmark ==="
echo "Target: ${BOJ_URL}"
echo "Iterations: ${ITERATIONS}"
echo ""

bench() {
  local desc="$1" tool="$2" args="$3"
  local start end elapsed avg

  start=$(date +%s%N)
  for _ in $(seq 1 "$ITERATIONS"); do
    curl -s -X POST "${BOJ_URL}/mcp/affinescript-mcp" \
      -H "Content-Type: application/json" \
      -d "{\"tool\": \"${tool}\", \"args\": ${args}}" > /dev/null 2>&1
  done
  end=$(date +%s%N)
  elapsed=$(( (end - start) / 1000000 ))
  avg=$(( elapsed / ITERATIONS ))
  echo "${desc}: ${elapsed}ms total, ${avg}ms avg"
}

bench "syntax_ref (pure lookup)" "affinescript_syntax_ref" '{"construct": "fn"}'
bench "explain_error (pure lookup)" "affinescript_explain_error" '{"code": "E2001"}'
bench "stdlib_search (pure lookup)" "affinescript_stdlib" '{"query": "Option"}'
bench "format (pure transform)" "affinescript_format" '{"source": "fn main() {\nlet x = 1\n}"}'

echo ""
echo "Done."
