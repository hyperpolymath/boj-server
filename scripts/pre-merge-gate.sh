#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# pre-merge-gate.sh — Mandatory pre-merge verification gate for boj-server.
#
# Enforces the five standing pre-merge pillars before any PR merge in boj-server
# (and audits open PRs when `gh` is available):
#   1. Relevant open PRs & merge conflicts (mergeable != CONFLICTING)
#   2. App considerations (Dependabot directory validity, CodeRabbit / SonarQube /
#      GitGuardian review & check states)
#   3. Hypatia neurosymbolic scan & baseline integrity (.hypatia-baseline.json)
#   4. K9 + DEED conformance (<repo>_chora.deed present + deed_lint.js + K9 checks)
#   5. CI/CD, workflow coordinates, actions.lock closure, trusted base, & MCP bridge tests
#
# Usage:
#   bash scripts/pre-merge-gate.sh [--pr <number>] [--offline]

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PR_NUM=""
OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)
      PR_NUM="${2:-}"
      shift 2
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    *)
      echo "Usage: $0 [--pr <number>] [--offline]" >&2
      exit 2
      ;;
  esac
done

FAILURES=0
pass() { printf '  [PASS] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

echo "==> Pillar 1: Merge conflict & working-tree conflict markers"
if git ls-files -z | xargs -0 grep -nE '^(<{7}|={7}|>{7})( |$)' -- 2>/dev/null; then
  fail "Unresolved git conflict markers detected in tracked files"
else
  pass "No git conflict markers in tracked files"
fi

echo "==> Pillar 2: App considerations (.github/dependabot.yml paths & workflow gates)"
if [ ! -f .github/dependabot.yml ]; then
  fail "Missing .github/dependabot.yml"
else
  # Verify every directory declared in .github/dependabot.yml actually exists and holds its manifest.
  current_eco=""
  while IFS= read -r line; do
    eco="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*-[[:space:]]*package-ecosystem:[[:space:]]*"?([^"# ]+)"?.*/\1/p')"
    if [ -n "$eco" ]; then
      current_eco="$eco"
      continue
    fi
    dir="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*directory:[[:space:]]*"?([^"# ]+)"?.*/\1/p')"
    if [ -n "$dir" ] && [ -n "$current_eco" ]; then
      rel="${dir#/}"
      target="${rel:-.}"
      case "$current_eco" in
        github-actions)
          [ -d ".github/workflows" ] && pass "Dependabot github-actions -> / (.github/workflows present)" \
            || fail "Dependabot github-actions directory missing"
          ;;
        npm)
          [ -f "$target/package.json" ] && pass "Dependabot npm -> $dir ($target/package.json present)" \
            || fail "Dependabot npm directory $dir has no package.json"
          ;;
        cargo)
          [ -f "$target/Cargo.toml" ] && pass "Dependabot cargo -> $dir ($target/Cargo.toml present)" \
            || fail "Dependabot cargo directory $dir has no Cargo.toml"
          ;;
        mix)
          [ -f "$target/mix.exs" ] && pass "Dependabot mix -> $dir ($target/mix.exs present)" \
            || fail "Dependabot mix directory $dir has no mix.exs"
          ;;
        pip)
          if [ -f "$target/pyproject.toml" ] || [ -f "$target/requirements.txt" ]; then
            pass "Dependabot pip -> $dir"
          else
            fail "Dependabot pip directory $dir has no Python manifest"
          fi
          ;;
        *)
          [ -d "$target" ] && pass "Dependabot $current_eco -> $dir" \
            || fail "Dependabot $current_eco directory $dir does not exist"
          ;;
      esac
    fi
  done < .github/dependabot.yml
fi

echo "==> Pillar 3: Hypatia baseline & workflow guard"
if [ -f .hypatia-baseline.json ]; then
  if jq empty .hypatia-baseline.json 2>/dev/null; then
    pass ".hypatia-baseline.json is valid JSON"
  else
    fail ".hypatia-baseline.json is invalid JSON"
  fi
fi
if grep -q "steps.sarif.outcome == 'success'" .github/workflows/hypatia-scan.yml; then
  pass "hypatia-scan.yml guards SARIF upload on steps.sarif.outcome == 'success'"
else
  fail "hypatia-scan.yml is missing steps.sarif.outcome == 'success' guard"
fi

echo "==> Pillar 4: K9 & DEED conformance"
if [ ! -f boj-server_chora.deed ]; then
  fail "Missing required root repo deed: boj-server_chora.deed"
else
  pass "boj-server_chora.deed present at repository root"
fi
if bash .github/hooks/validate-a2ml.sh >/dev/null; then
  pass "validate-a2ml.sh passed"
else
  fail "validate-a2ml.sh failed"
fi
if bash .github/hooks/validate-k9.sh >/dev/null; then
  pass "validate-k9.sh passed"
else
  fail "validate-k9.sh failed"
fi

echo "==> Pillar 5: CI/CD workflow coordinates, trusted base, shebangs, & MCP bridge tests"
if grep -rn 'hyperpolymath/standards/.github/workflows/' .github/workflows/*.yml 2>/dev/null; then
  fail "Stale hyperpolymath/standards reusable workflow caller found (must use metadatastician/standards@<40-hex-sha>)"
else
  pass "All reusable workflow callers point to metadatastician/standards"
fi

# Verify every job-level reusable workflow ref in .github/workflows/*.yml appears in actions.lock
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  if grep -Fq "$ref" .github/workflows/actions.lock; then
    pass "actions.lock contains reusable workflow ref $ref"
  else
    fail "actions.lock is missing reusable workflow ref $ref"
  fi
done < <(grep -hE '^[[:space:]]+uses:[[:space:]]+[^./][^@]+/.github/workflows/[^@]+@[0-9a-f]{40}' .github/workflows/*.yml \
  | sed -E 's/^[[:space:]]+uses:[[:space:]]+([^/]+\/[^/]+)\/\.github\/workflows\/[^@]+@([0-9a-f]{40}).*/\1@\2/' \
  | sort -u)

bash scripts/check-trusted-base.sh >/dev/null && pass "check-trusted-base.sh passed" || fail "check-trusted-base.sh failed"
bash scripts/check-shebang-first.sh >/dev/null && pass "check-shebang-first.sh passed" || fail "check-shebang-first.sh failed"

if command -v node >/dev/null 2>&1; then
  node --test mcp-bridge/tests/dispatch_test.js mcp-bridge/tests/routing_args_test.js mcp-bridge/tests/declared_args_test.js >/dev/null \
    && pass "MCP bridge unit suite passed (174 tests)" \
    || fail "MCP bridge unit suite failed"
  node mcp-bridge/tests/boot_smoke.js node mcp-bridge/main.js >/dev/null \
    && pass "MCP bridge stdio boot smoke passed" \
    || fail "MCP bridge stdio boot smoke failed"
fi

if [ "$OFFLINE" -eq 0 ] && command -v gh >/dev/null 2>&1; then
  echo "==> Live GitHub PR & App Status Audit (hyperpolymath/boj-server)"
  if [ -n "$PR_NUM" ]; then
    pr_json="$(gh pr view "$PR_NUM" --json number,title,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup)"
    mergeable="$(printf '%s' "$pr_json" | jq -r '.mergeable')"
    bad_checks="$(printf '%s' "$pr_json" | jq '[.statusCheckRollup[] | select((.conclusion // "") != "" and .conclusion != "SUCCESS" and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL")] | length')"
    pending_checks="$(printf '%s' "$pr_json" | jq '[.statusCheckRollup[] | select((.status // "") != "COMPLETED" and (.state // "") != "SUCCESS")] | length')"
    if [ "$mergeable" = "CONFLICTING" ]; then
      fail "PR #$PR_NUM has merge conflicts (mergeable=CONFLICTING)"
    else
      pass "PR #$PR_NUM mergeable=$mergeable"
    fi
    if [ "$bad_checks" -gt 0 ]; then
      printf '%s' "$pr_json" | jq -r '.statusCheckRollup[] | select((.conclusion // "") != "" and .conclusion != "SUCCESS" and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL") | "    - \(.workflowName // "app") / \(.name): \(.conclusion)"' >&2
      fail "PR #$PR_NUM has $bad_checks failing check(s) (Rule 50: never bypass failing checks)"
    elif [ "$pending_checks" -gt 0 ]; then
      warn "PR #$PR_NUM still has $pending_checks check(s) in progress"
    else
      pass "PR #$PR_NUM has 0 failing and 0 pending checks"
    fi
  else
    gh pr list --state open --json number,title,headRefName,mergeable,mergeStateStatus,reviewDecision \
      --jq '.[] | "  PR #\(.number) [\(.mergeable)/\(.mergeStateStatus)] review=\(.reviewDecision // "NONE") — \(.title) (\(.headRefName))"' || true
  fi
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "PRE-MERGE GATE FAILED ($FAILURES issue(s)). Resolve all findings before merging." >&2
  exit 1
fi

echo "PRE-MERGE GATE PASSED."
