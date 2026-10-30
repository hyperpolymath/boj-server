#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# pre-merge-gate.sh — Mandatory pre-merge verification gate for boj-server.
#
# Enforces the five standing pre-merge pillars before any PR merge in boj-server:
#   1. Open PRs & merge conflicts (mergeable != CONFLICTING)
#   2. App considerations (.github/dependabot.yml directory/manifest/path-dep
#      validity + CodeRabbit / Codex / GitGuardian review & check states)
#   3. Hypatia neurosymbolic scan guard & optional .hypatia-baseline.json JSON check
#   4. K9 + DEED conformance (boj-server_chora.deed + validate-a2ml.sh +
#      validate-k9.sh, plus canonical deed_lint.js & k9-validate.sh when
#      STANDARDS_DIR is configured)
#   5. CI/CD workflow coordinates, full actions.lock coverage across all step &
#      job-level `uses:` references, trusted-base audit, shebang check, and MCP
#      bridge unit + stdio boot smoke tests.
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
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "Usage: $0 [--pr <number>] [--offline]" >&2
        exit 2
      fi
      PR_NUM="$2"
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

if [ -n "$PR_NUM" ] && [ "$OFFLINE" -eq 1 ]; then
  echo "ERROR: --pr cannot be combined with --offline" >&2
  exit 2
fi

FAILURES=0
pass() { printf '  [PASS] %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

check_dependabot_dir() {
  local eco="$1" dir="$2" rel target
  rel="${dir#/}"
  target="${rel:-.}"
  case "$eco" in
    github-actions)
      [ -d ".github/workflows" ] \
        && pass "Dependabot github-actions -> $dir (.github/workflows present)" \
        || fail "Dependabot github-actions directory missing"
      ;;
    npm)
      [ -f "$target/package.json" ] \
        && pass "Dependabot npm -> $dir ($target/package.json present)" \
        || fail "Dependabot npm directory $dir has no package.json"
      ;;
    cargo)
      if [ ! -f "$target/Cargo.toml" ]; then
        fail "Dependabot cargo directory $dir has no Cargo.toml"
      elif grep -qE 'path[[:space:]]*=[[:space:]]*"\.\./' "$target/Cargo.toml"; then
        # Verify any relative path dependency stays inside the repository root
        local bad_path=0 p resolved
        while IFS= read -r p; do
          [ -z "$p" ] && continue
          resolved="$(realpath -m "$target/$p")"
          case "$resolved" in
            "$ROOT"|"$ROOT"/*) ;;
            *) bad_path=1; fail "Dependabot cargo $dir has out-of-repo path dependency: $p" ;;
          esac
        done < <(sed -nE 's/.*path[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$target/Cargo.toml")
        [ "$bad_path" -eq 0 ] && pass "Dependabot cargo -> $dir ($target/Cargo.toml present & repo-contained)"
      else
        pass "Dependabot cargo -> $dir ($target/Cargo.toml present)"
      fi
      ;;
    mix)
      [ -f "$target/mix.exs" ] \
        && pass "Dependabot mix -> $dir ($target/mix.exs present)" \
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
      [ -d "$target" ] \
        && pass "Dependabot $eco -> $dir" \
        || fail "Dependabot $eco directory $dir does not exist"
      ;;
  esac
}

echo "==> Pillar 1: Merge conflict markers in tracked files"
if git ls-files -z | xargs -0 grep -nE '^(<{7}|={7}|>{7})( |$)' -- 2>/dev/null; then
  fail "Unresolved git conflict markers detected in tracked files"
else
  pass "No git conflict markers in tracked files"
fi

echo "==> Pillar 2: App considerations (.github/dependabot.yml paths & standalone manifests)"
if [ ! -f .github/dependabot.yml ]; then
  fail "Missing .github/dependabot.yml"
else
  current_eco=""
  in_dirs_list=0
  dirs_checked=0
  while IFS= read -r line; do
    eco="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*-[[:space:]]*package-ecosystem:[[:space:]]*"?([^"# ]+)"?.*/\1/p')"
    if [ -n "$eco" ]; then
      current_eco="$eco"
      in_dirs_list=0
      continue
    fi
    if printf '%s' "$line" | grep -qE '^[[:space:]]*directories:[[:space:]]*(#.*)?$'; then
      in_dirs_list=1
      continue
    fi
    if [ "$in_dirs_list" -eq 1 ]; then
      list_dir="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*-[[:space:]]*"?([^"# ]+)"?.*/\1/p')"
      if [ -n "$list_dir" ] && [ -n "$current_eco" ]; then
        check_dependabot_dir "$current_eco" "$list_dir"
        dirs_checked=$((dirs_checked + 1))
        continue
      elif printf '%s' "$line" | grep -qE '^[[:space:]]*[a-zA-Z_-]+:'; then
        in_dirs_list=0
      fi
    fi
    dir="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*directory:[[:space:]]*"?([^"# ]+)"?.*/\1/p')"
    if [ -n "$dir" ] && [ -n "$current_eco" ]; then
      check_dependabot_dir "$current_eco" "$dir"
      dirs_checked=$((dirs_checked + 1))
    fi
  done < .github/dependabot.yml
  if [ "$dirs_checked" -eq 0 ]; then
    fail "No Dependabot directory entries parsed from .github/dependabot.yml"
  fi
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

STANDARDS_CHECKOUT="${STANDARDS_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/hyperpolymath/standards}"
if [ -d "$STANDARDS_CHECKOUT/1-formats" ]; then
  DEED_LINT="$STANDARDS_CHECKOUT/1-formats/deed/tools/deed_lint.js"
  K9_VALIDATOR="$STANDARDS_CHECKOUT/1-formats/k9/tools/k9-validate.sh"
  mapfile -t deed_files < <(git ls-files -- '*.deed' | sort)
  if [ -f "$DEED_LINT" ] && [ "${#deed_files[@]}" -gt 0 ]; then
    if command -v deno >/dev/null 2>&1; then
      deno run --allow-read "$DEED_LINT" "${deed_files[@]}" >/dev/null \
        && pass "canonical deed_lint.js passed (${#deed_files[@]} file(s) via deno)" \
        || fail "canonical deed_lint.js failed"
    elif command -v node >/dev/null 2>&1; then
      node "$DEED_LINT" "${deed_files[@]}" >/dev/null \
        && pass "canonical deed_lint.js passed (${#deed_files[@]} file(s) via node)" \
        || fail "canonical deed_lint.js failed"
    elif command -v bun >/dev/null 2>&1; then
      bun "$DEED_LINT" "${deed_files[@]}" >/dev/null \
        && pass "canonical deed_lint.js passed (${#deed_files[@]} file(s) via bun)" \
        || fail "canonical deed_lint.js failed"
    else
      fail "No JS runtime (deno/node/bun) available to run canonical deed_lint.js"
    fi
  fi
  mapfile -t k9_files < <(git ls-files -- '*.k9' '*.k9.ncl' | sort)
  if [ -f "$K9_VALIDATOR" ] && [ "${#k9_files[@]}" -gt 0 ]; then
    if command -v nickel >/dev/null 2>&1; then
      bash "$K9_VALIDATOR" --layer L2 --strict "${k9_files[@]}" >/dev/null \
        && pass "canonical k9-validate.sh L0+L1+L2 passed (${#k9_files[@]} file(s))" \
        || fail "canonical k9-validate.sh L0+L1+L2 failed"
    else
      bash "$K9_VALIDATOR" --layer L1 "${k9_files[@]}" >/dev/null \
        && warn "canonical k9-validate.sh L0+L1 passed (install nickel for local L2; Dogfood Gate runs L2 in CI)" \
        || fail "canonical k9-validate.sh L0+L1 failed"
    fi
  fi
else
  warn "STANDARDS_DIR not set — canonical deed_lint.js & k9-validate.sh L2 run in CI (Dogfood Gate)"
fi

echo "==> Pillar 5: CI/CD workflow coordinates, actions.lock coverage, trusted base, & MCP bridge tests"
# 5a. Validate every job-level reusable workflow coordinate has an approved owner and 40-hex SHA pin.
reusable_bad=0
reusable_count=0
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  wf_file="${entry%%:*}"
  coord="${entry#*:}"
  reusable_count=$((reusable_count + 1))
  case "$coord" in
    hyperpolymath/standards/.github/workflows/*@[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*|\
    metadatastician/standards/.github/workflows/*@[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*|\
    slsa-framework/slsa-github-generator/.github/workflows/*@[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      pin="${coord##*@}"
      if ! printf '%s' "$pin" | grep -qE '^[0-9a-f]{40}$'; then
        fail "$wf_file reusable workflow $coord is not pinned to a full 40-hex SHA"
        reusable_bad=1
      fi
      ;;
    *)
      fail "$wf_file uses unapproved or unpinned reusable workflow coordinate: $coord"
      reusable_bad=1
      ;;
  esac
done < <(grep -H -E '^[[:space:]]+uses:[[:space:]]+[^./][^[:space:]]+/\.github/workflows/[^[:space:]]+' .github/workflows/*.yml \
  | sed -E 's|^([^:]+):[[:space:]]+uses:[[:space:]]+([^[:space:]#]+).*|\1:\2|')
if [ "$reusable_bad" -eq 0 ]; then
  pass "All $reusable_count reusable workflow caller(s) use approved owners and 40-hex SHA pins"
fi

# 5b. Validate every external step-level and job-level `uses:` in every workflow file against actions.lock.
if [ ! -f .github/workflows/actions.lock ]; then
  fail "Missing .github/workflows/actions.lock"
else
  lock_bad=0
  lock_checked=0
  for wf in .github/workflows/*.yml; do
    while IFS= read -r raw_ref; do
      [ -z "$raw_ref" ] && continue
      case "$raw_ref" in
        ./*|docker://*) continue ;;
      esac
      # Normalize owner/repo[/subpath]@ref -> lower(owner/repo)@ref (gh actions-lock key shape)
      owner_repo="$(printf '%s' "$raw_ref" | sed -E 's|^([^/@]+/[^/@]+).*@.*|\1|' | tr '[:upper:]' '[:lower:]')"
      ref_part="${raw_ref##*@}"
      lock_key="${owner_repo}@${ref_part}"
      lock_checked=$((lock_checked + 1))

      # Check workflow section membership for $wf AND dependency record presence.
      wf_listed="$(awk -v w="    '$wf':" -v k="        - '$lock_key'" '
        $0 == w { in_wf=1; next }
        in_wf && /^    '\''\.github\/workflows\// { in_wf=0 }
        in_wf && /^dependencies:/ { in_wf=0 }
        in_wf && $0 == k { found=1; exit }
        END { print (found ? 1 : 0) }
      ' .github/workflows/actions.lock)"
      dep_listed="$( grep -Fq "    '$lock_key':" .github/workflows/actions.lock && echo 1 || echo 0 )"
      if [ "$wf_listed" -ne 1 ] || [ "$dep_listed" -ne 1 ]; then
        fail "$wf uses $raw_ref ($lock_key) missing from .github/workflows/actions.lock"
        lock_bad=1
      fi
    done < <(sed -E 's/#.*//' "$wf" \
      | grep -E '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[^[:space:]]+' \
      | sed -E "s/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*['\"]?([^'\"[:space:]]+)['\"]?.*/\2/" \
      | sort -u)
  done
  if [ "$lock_bad" -eq 0 ]; then
    pass "All $lock_checked external workflow uses: reference(s) are locked in actions.lock"
  fi
fi

bash scripts/check-trusted-base.sh >/dev/null && pass "check-trusted-base.sh passed" || fail "check-trusted-base.sh failed"
bash scripts/check-shebang-first.sh >/dev/null && pass "check-shebang-first.sh passed" || fail "check-shebang-first.sh failed"

if command -v deno >/dev/null 2>&1; then
  deno test --allow-read --allow-env --allow-run --allow-net \
    mcp-bridge/tests/dispatch_test.js mcp-bridge/tests/routing_args_test.js mcp-bridge/tests/declared_args_test.js >/dev/null 2>&1 \
    && pass "MCP bridge unit suite passed via deno (174 tests)" \
    || fail "MCP bridge unit suite failed under deno"
elif command -v node >/dev/null 2>&1; then
  node --test mcp-bridge/tests/dispatch_test.js mcp-bridge/tests/routing_args_test.js mcp-bridge/tests/declared_args_test.js >/dev/null \
    && pass "MCP bridge unit suite passed via node (174 tests)" \
    || fail "MCP bridge unit suite failed under node"
elif command -v bun >/dev/null 2>&1; then
  bun test mcp-bridge/tests/dispatch_test.js mcp-bridge/tests/routing_args_test.js mcp-bridge/tests/declared_args_test.js >/dev/null 2>&1 \
    && pass "MCP bridge unit suite passed via bun (174 tests)" \
    || fail "MCP bridge unit suite failed under bun"
else
  fail "No supported JS runtime (deno, node, or bun) found on PATH to run MCP bridge tests"
fi

if command -v node >/dev/null 2>&1; then
  node mcp-bridge/tests/boot_smoke.js node mcp-bridge/main.js >/dev/null \
    && pass "MCP bridge stdio boot smoke passed" \
    || fail "MCP bridge stdio boot smoke failed"
elif command -v deno >/dev/null 2>&1; then
  deno run --allow-read --allow-run --allow-env mcp-bridge/tests/boot_smoke.js deno run --allow-net --allow-env --allow-read mcp-bridge/main.js >/dev/null \
    && pass "MCP bridge stdio boot smoke passed (deno)" \
    || fail "MCP bridge stdio boot smoke failed (deno)"
fi

audit_single_pr() {
  local num="$1" pr_json mergeable review_decision bad_checks pending_checks title
  if ! pr_json="$(gh pr view "$num" --json number,title,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup)"; then
    fail "Failed to query PR #$num via gh"
    return
  fi
  title="$(printf '%s' "$pr_json" | jq -r '.title')"
  mergeable="$(printf '%s' "$pr_json" | jq -r '.mergeable')"
  review_decision="$(printf '%s' "$pr_json" | jq -r '.reviewDecision // ""')"
  bad_checks="$(printf '%s' "$pr_json" | jq '[.statusCheckRollup[] | select(
    ((.conclusion // "") != "" and (.conclusion != "SUCCESS" and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL"))
    or ((.state // "") == "FAILURE" or (.state // "") == "ERROR")
  )] | length')"
  pending_checks="$(printf '%s' "$pr_json" | jq '[.statusCheckRollup[] | select(
    ((.__typename // "") == "CheckRun" and (.status // "") != "COMPLETED")
    or ((.__typename // "") == "StatusContext" and ((.state // "") == "PENDING" or (.state // "") == "EXPECTED"))
  )] | length')"

  if [ "$mergeable" = "CONFLICTING" ]; then
    fail "PR #$num ($title) has merge conflicts (mergeable=CONFLICTING)"
  else
    pass "PR #$num mergeable=$mergeable"
  fi

  if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
    fail "PR #$num ($title) has CHANGES_REQUESTED review state"
  else
    pass "PR #$num reviewDecision=${review_decision:-NONE}"
  fi

  if [ "$bad_checks" -gt 0 ]; then
    printf '%s' "$pr_json" | jq -r '.statusCheckRollup[] | select(
      ((.conclusion // "") != "" and (.conclusion != "SUCCESS" and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL"))
      or ((.state // "") == "FAILURE" or (.state // "") == "ERROR")
    ) | "    - \(.workflowName // .context // "app") / \(.name // .context): \(.conclusion // .state)"' >&2
    fail "PR #$num ($title) has $bad_checks failing check(s) (Rule 50: never bypass failing checks)"
  elif [ "$pending_checks" -gt 0 ]; then
    fail "PR #$num ($title) still has $pending_checks check(s) in progress — wait for green before merging"
  else
    pass "PR #$num ($title) has 0 failing and 0 pending checks"
  fi
}

if [ "$OFFLINE" -eq 0 ]; then
  echo "==> Live GitHub PR & App Status Audit (hyperpolymath/boj-server)"
  if ! command -v gh >/dev/null 2>&1; then
    fail "gh CLI is required for live PR verification (pass --offline only for local pre-PR checks)"
  elif [ -n "$PR_NUM" ]; then
    audit_single_pr "$PR_NUM"
  else
    open_prs_json="$(gh pr list --state open --json number)" || {
      fail "Failed to list open PRs via gh"
      open_prs_json="[]"
    }
    mapfile -t open_pr_nums < <(printf '%s' "$open_prs_json" | jq -r '.[].number')
    if [ "${#open_pr_nums[@]}" -eq 0 ]; then
      pass "No open PRs on hyperpolymath/boj-server"
    else
      for pnum in "${open_pr_nums[@]}"; do
        audit_single_pr "$pnum"
      done
    fi
  fi
else
  warn "Live GitHub PR & App audit skipped (--offline mode)"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "PRE-MERGE GATE FAILED ($FAILURES issue(s)). Resolve all findings before merging." >&2
  exit 1
fi

echo "PRE-MERGE GATE PASSED."
