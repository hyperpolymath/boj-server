#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# hcg-surface-drift-check.sh — Asserts that every wired BoJ HTTP route
# is covered by at least one rule in the HCG live Verb Governance Spec.
#
# The HCG live policy file (`config/gateway-policy-boj.yaml`) carries a
# manual re-verification stamp ("Re-verified DATE against BojRest.Router
# for HCG tier-2 rollout"). The ADR's largest declared risk is "policy
# lagging the surface": a wired route landing without a matching policy
# rule would default-deny in production (an outage on a route that
# should be live), and the manual stamp is the only check today that
# catches this.
#
# This script automates the same check so the stamp becomes machine-
# checkable. Algorithm:
#
#   1. Extract (verb, path-template) tuples from
#      `elixir/lib/boj_rest/router.ex` — every `get "/..."`,
#      `post "/..."`, etc. at the top level of the router module.
#   2. Extract (verb, path-pattern) tuples from
#      `config/gateway-policy-boj.yaml` — every `- path: "..."` /
#      `verbs: [...]` pair under `governance.routes`.
#   3. For each wired route, concretise its `:name`-style placeholders
#      with a known probe segment (`probe`, matching the smoke
#      script) and assert at least one policy rule matches:
#        * literal policy path → exact equality with the concrete URL
#        * regex policy path (leading `^`) → `grep -E` match against
#          the concrete URL
#      The router method must be in the policy rule's verb list.
#   4. Report any wired-but-ungoverned routes (drift) and exit 1; or
#      exit 0 if every wired route is covered.
#
# Bracket-style relationship with `scripts/hcg-policy-smoke.sh`:
#   * Smoke script runs against a *live gateway* to confirm the policy
#     enforces as declared (deny path / allow path / stealth status).
#   * Drift check runs against the *source files* to confirm the policy
#     still covers the wired surface.
# Together they cover both halves of the §1.5 pre-rollout verification:
# surface→policy coverage (this script) and policy→gateway enforcement
# (the smoke script).
#
# Usage:
#   ./scripts/hcg-surface-drift-check.sh          # uses repo defaults
#   ./scripts/hcg-surface-drift-check.sh -v       # verbose; list matches
#
# Exit codes:
#   0  — no drift; every wired route is covered.
#   1  — drift detected; at least one wired route has no matching rule.
#   64 — bad usage.
#
# Limitations (called out so the operator does not over-trust the
# OK result):
#   * Parses the router with regex, not the Elixir AST. Routes declared
#     via macros, list comprehensions, or runtime registration are NOT
#     seen. The current router declares every route at the top level
#     with the Plug.Router DSL, which the regex handles correctly; a
#     future indirection would require this script to evolve.
#   * The "concretise `:name` with a fixed probe" step assumes the
#     policy regex character class accepts the probe segment. The
#     current policy uses `[A-Za-z0-9_.-]+`, which accepts `probe`;
#     a tightened class might not. Change the probe via `PROBE=` env
#     var if needed.
#   * Does NOT report orphan policy rules (rules with no matching
#     router route). This is intentional: the policy governs declared-
#     not-yet-wired routes per contract §8 (`http-capability-gateway-
#     boj-contract.md` §8). An orphan-rule check would have to also
#     consult `docs/specification/openapi.yaml` to suppress those
#     intentional cases; out of scope for this script.
#
# Cross-refs:
#   docs/integration/hcg-tier2-rollout-runbook.md   §1.5
#   docs/integration/http-capability-gateway-boj-contract.md §8 ("Surface drift caveat")
#   docs/integration/http-capability-gateway-policy-authoring.md §5 ("Review & versioning discipline")
#   config/gateway-policy-boj.yaml                  source of truth
#   scripts/hcg-policy-smoke.sh                     companion enforcement check
#   standards#100                                   tracking issue

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTER_FILE="${ROUTER_FILE:-${REPO_ROOT}/elixir/lib/boj_rest/router.ex}"
POLICY_FILE="${POLICY_FILE:-${REPO_ROOT}/config/gateway-policy-boj.yaml}"
PROBE="${PROBE:-probe}"
VERBOSE=0

usage() {
    cat >&2 <<'EOF'
hcg-surface-drift-check.sh — assert wired-router-route ⊆ policy-rules.

USAGE:
  hcg-surface-drift-check.sh [-v] [-h]

OPTIONS:
  -v        Verbose; print each wired route and the policy rule
            that matches it.
  -h        Show this help.

ENV:
  ROUTER_FILE   Override router path (default elixir/lib/boj_rest/router.ex).
  POLICY_FILE   Override policy path (default config/gateway-policy-boj.yaml).
  PROBE         Placeholder segment substituted for `:name`-style
                router parameters (default "probe").

EXIT CODES:
  0  no drift; every wired route covered by a policy rule.
  1  drift detected (at least one wired route has no match).
  64 bad usage.

Cross-refs:
  docs/integration/hcg-tier2-rollout-runbook.md §1.5
  scripts/hcg-policy-smoke.sh                   companion check
EOF
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        -v) VERBOSE=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

[ -f "$ROUTER_FILE" ] || { echo "router file not found: $ROUTER_FILE" >&2; exit 1; }
[ -f "$POLICY_FILE" ] || { echo "policy file not found: $POLICY_FILE" >&2; exit 1; }

# 1. Wired routes from router.ex.
#
# Plug.Router DSL: top-level `get "/foo"` / `post "/foo"` etc. Output
# format: VERB<TAB>/path/template, one route per line. The router's
# `match _` catch-all is intentionally not captured.
wired=$(
    grep -E '^[[:space:]]*(get|post|put|delete|patch|head|options)[[:space:]]+"[^"]+"' "$ROUTER_FILE" \
    | awk '{
        verb_lc = $1
        # POSIX-portable upper-case via tr in a subshell.
        cmd = "printf %s " verb_lc " | tr a-z A-Z"
        cmd | getline VERB
        close(cmd)
        # Extract the path inside the first pair of double quotes.
        line = $0
        sub(/^[^"]*"/, "", line)
        sub(/".*/, "", line)
        print VERB "\t" line
      }'
)

# 2. Policy rules from gateway-policy-boj.yaml.
#
# Each rule is a `- path: "..."` line under `governance.routes:`,
# followed (on a later indented line) by `verbs: [GET, POST, ...]`.
# We expand the verb list to one row per (verb, path) so the matching
# loop below stays a single nested for-loop. Comments outside the
# routes block are skipped because the regexes do not match them.
policy=$(
    awk '
    /^[[:space:]]*-[[:space:]]+path:[[:space:]]*"/ {
        line = $0
        sub(/^[^"]*"/, "", line)
        sub(/".*/, "", line)
        cur_path = line
        next
    }
    /^[[:space:]]+verbs:[[:space:]]*\[/ {
        line = $0
        sub(/^[^\[]*\[/, "", line)
        sub(/\].*/, "", line)
        gsub(/[[:space:]]/, "", line)
        n = split(line, vs, ",")
        for (i = 1; i <= n; i++) {
            print vs[i] "\t" cur_path
        }
    }
    ' "$POLICY_FILE"
)

# 3. For each wired route, find a covering policy rule.
#
# Concretise `:name`-style segments with $PROBE so regex policy paths
# (`^/cartridge/[A-Za-z0-9_.-]+/invoke$` etc.) can be tested against
# a real URL string. The PROBE default ("probe") is shared with the
# smoke script so a future tightening of the regex character class
# fails both checks in lock-step instead of one silently.
drift=0
drift_msgs=()
match_msgs=()
while IFS=$'\t' read -r verb tmpl; do
    [ -z "${verb:-}" ] && continue
    # Substitute `:identifier` segments with the probe placeholder.
    # `:name` → `probe`, `:cartridge_id` → `probe`, etc.
    concrete=$(printf '%s' "$tmpl" | sed -E "s|:[a-zA-Z_][a-zA-Z0-9_]*|${PROBE}|g")

    matched_rule=""
    while IFS=$'\t' read -r p_verb p_path; do
        [ -z "${p_verb:-}" ] && continue
        [ "$verb" = "$p_verb" ] || continue
        case "$p_path" in
            \^*)
                # Regex pattern — ERE match against the concrete URL.
                if printf '%s' "$concrete" | grep -qE "$p_path"; then
                    matched_rule="$p_verb $p_path"
                    break
                fi
                ;;
            *)
                # Literal pattern — exact string equality.
                if [ "$concrete" = "$p_path" ]; then
                    matched_rule="$p_verb $p_path"
                    break
                fi
                ;;
        esac
    done <<< "$policy"

    if [ -z "$matched_rule" ]; then
        drift_msgs+=("$verb $tmpl  (concrete: $concrete)")
        drift=$((drift + 1))
    else
        match_msgs+=("$verb $tmpl  →  $matched_rule")
    fi
done <<< "$wired"

echo "==> HCG surface drift check"
echo "    Router file: $ROUTER_FILE"
echo "    Policy file: $POLICY_FILE"
echo "    Probe placeholder: '$PROBE'"
wired_count=$(printf '%s\n' "$wired" | grep -c . || true)
policy_count=$(printf '%s\n' "$policy" | grep -c . || true)
echo "    Wired (router) routes:    $wired_count"
echo "    Policy (verb,path) rules: $policy_count"
echo

if [ "$VERBOSE" = "1" ] && [ ${#match_msgs[@]} -gt 0 ]; then
    echo "Matched:"
    for m in "${match_msgs[@]}"; do
        printf '  %s\n' "$m"
    done
    echo
fi

if [ "$drift" -eq 0 ]; then
    echo "OK: every wired router route is covered by at least one policy rule."
    echo "The §1.5 re-verification stamp in config/gateway-policy-boj.yaml"
    echo "can be advanced safely after manual review of any policy edits."
    exit 0
fi

echo "DRIFT: $drift wired router route(s) are not covered by any policy rule:"
for m in "${drift_msgs[@]}"; do
    printf '  - %s\n' "$m"
done
echo
echo "Resolution: add a matching rule to config/gateway-policy-boj.yaml"
echo "(and config/gateway-policy-boj-example.yaml if the route is part of"
echo "the pedagogical surface). See docs/integration/http-capability-"
echo "gateway-policy-authoring.md §5 for the co-change discipline."
exit 1
