#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# hcg-spec-coverage-check.sh — Asserts that every HTTP route declared in
# `docs/specification/openapi.yaml` is covered by at least one rule in
# the HCG live Verb Governance Spec (`config/gateway-policy-boj.yaml`).
#
# Contract §8 (`docs/integration/http-capability-gateway-boj-contract.md`)
# is explicit: the Verb Governance Spec governs the **declared** surface
# (openapi.yaml), not only the currently-wired subset. Declared-but-not-
# yet-wired routes are classified in the policy in advance so that the
# day a gnosis handler grows them they are governed from day one rather
# than silently exposed. The §1.5 pre-rollout checklist relies on the
# live policy header's manual cross-check statement
# ("Surface source: docs/specification/openapi.yaml, cross-checked
# against elixir/lib/boj_rest/router.ex") to make this hold; this script
# automates the openapi-side half so the statement becomes machine-
# checkable.
#
# Companion / complement to `scripts/hcg-surface-drift-check.sh`:
#
#   surface-drift     wired (router.ex) ⊆ policy   — catches policy lag
#                                                    behind wiring (a
#                                                    default-deny outage
#                                                    on a route that
#                                                    should be live)
#   spec-coverage     declared (openapi.yaml) ⊆ policy
#                                                  — catches policy lag
#                                                    behind the spec
#                                                    (a route appearing
#                                                    in BoJ's declared
#                                                    HTTP surface with no
#                                                    governance, which
#                                                    would then default-
#                                                    deny the day it is
#                                                    wired)
#
# Together they enforce contract §8 from both directions: any route the
# gateway can ever be asked to serve — whether already wired or merely
# declared — has explicit governance before traffic reaches it.
#
# Algorithm:
#
#   1. Extract (verb, path-template) tuples from `paths:` in
#      `docs/specification/openapi.yaml`. Path entries are at exactly
#      2-space indent; HTTP operations (get/post/put/delete/patch/head/
#      options) are at exactly 4-space indent under each path. Other
#      keys at 4-space indent (parameters/summary/description/...) are
#      not HTTP operations and are skipped.
#   2. Extract (verb, path-pattern) tuples from
#      `config/gateway-policy-boj.yaml` — identical extraction to
#      `hcg-surface-drift-check.sh` so the two scripts cannot drift in
#      how they read the policy.
#   3. For each declared route, concretise `{name}`-style placeholders
#      with a known probe segment (`probe`, shared with the smoke and
#      surface-drift scripts so a future regex tightening fails all
#      three in lock-step) and assert at least one policy rule covers it:
#        * literal policy path → exact equality with the concrete URL
#        * regex policy path (leading `^`) → `grep -E` match
#      The declared verb must be in the policy rule's verb list.
#   4. Report any declared-but-ungoverned routes (gap) and exit 1; or
#      exit 0 if every declared route is covered.
#
# Usage:
#   ./scripts/hcg-spec-coverage-check.sh          # uses repo defaults
#   ./scripts/hcg-spec-coverage-check.sh -v       # verbose; list matches
#
# Exit codes:
#   0  — every declared route is covered.
#   1  — gap detected; at least one declared route has no matching rule.
#   64 — bad usage.
#
# Limitations (called out so the operator does not over-trust an OK):
#   * Parses openapi.yaml with regex, not a real YAML parser. The
#     current spec puts `paths:` at top level with path entries at
#     2-space indent and operations at 4-space indent — the standard
#     OpenAPI v3 layout the boj-server spec follows. A future spec that
#     uses different indentation, `$ref` inclusion across files, or
#     YAML aliases for paths would require this script to evolve.
#   * The "concretise `{name}` with a fixed probe" step assumes the
#     policy regex character class accepts the probe segment. The
#     current policy uses `[A-Za-z0-9_.-]+`, which accepts `probe`;
#     a tightened class might not. Change the probe via `PROBE=` env
#     var if needed (same knob as the surface-drift script).
#   * Does NOT enforce that policy rules whose paths are NOT declared
#     in openapi.yaml should be removed. The `/.well-known/boj-node-
#     pubkey` rule in `config/gateway-policy-boj.yaml` is an example
#     of a wired-but-spec-undeclared route the policy correctly
#     governs — penalising those would conflict with the surface-drift
#     check that requires it. Coverage of router-wired-but-spec-
#     undeclared routes is therefore policy ⊇ (router ∪ openapi), not
#     equality.
#
# Cross-refs:
#   docs/integration/hcg-tier2-rollout-runbook.md   §1.5
#   docs/integration/http-capability-gateway-boj-contract.md §8 ("Surface drift caveat")
#   docs/integration/http-capability-gateway-policy-authoring.md §5 ("Review & versioning discipline")
#   docs/specification/openapi.yaml                 source of declared surface
#   config/gateway-policy-boj.yaml                  source of governance
#   scripts/hcg-surface-drift-check.sh              companion (wired side)
#   scripts/hcg-policy-smoke.sh                     companion (live-gateway side)
#   standards#100                                   tracking issue

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENAPI_FILE="${OPENAPI_FILE:-${REPO_ROOT}/docs/specification/openapi.yaml}"
POLICY_FILE="${POLICY_FILE:-${REPO_ROOT}/config/gateway-policy-boj.yaml}"
PROBE="${PROBE:-probe}"
VERBOSE=0

usage() {
    cat >&2 <<'EOF'
hcg-spec-coverage-check.sh — assert declared-openapi-route ⊆ policy-rules.

USAGE:
  hcg-spec-coverage-check.sh [-v] [-h]

OPTIONS:
  -v        Verbose; print each declared route and the policy rule
            that matches it.
  -h        Show this help.

ENV:
  OPENAPI_FILE  Override openapi path (default docs/specification/openapi.yaml).
  POLICY_FILE   Override policy path (default config/gateway-policy-boj.yaml).
  PROBE         Placeholder segment substituted for `{name}`-style
                openapi parameters (default "probe").

EXIT CODES:
  0  no gap; every declared route covered by a policy rule.
  1  gap detected (at least one declared route has no match).
  64 bad usage.

Cross-refs:
  docs/integration/hcg-tier2-rollout-runbook.md §1.5
  docs/integration/http-capability-gateway-boj-contract.md §8
  scripts/hcg-surface-drift-check.sh                companion check
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

[ -f "$OPENAPI_FILE" ] || { echo "openapi file not found: $OPENAPI_FILE" >&2; exit 1; }
[ -f "$POLICY_FILE" ]  || { echo "policy file not found: $POLICY_FILE"  >&2; exit 1; }

# 1. Declared routes from openapi.yaml.
#
# `paths:` is at top-level (column 1); path entries are at exactly
# 2-space indent and end with `:`; HTTP operations (get/post/put/delete/
# patch/head/options) are at exactly 4-space indent under each path.
# Anything else at 4-space indent (parameters, summary, description,
# tags, ...) is metadata, not an operation, and is skipped. Output
# format: VERB<TAB>/path/template, one route per line.
declared=$(
    awk '
    BEGIN { in_paths = 0; cur_path = "" }
    # End of paths: section is the next top-level key (column-1 letter).
    /^[A-Za-z]/ {
        if (in_paths) { in_paths = 0; cur_path = "" }
    }
    /^paths:[[:space:]]*$/ { in_paths = 1; next }
    in_paths && /^  \/[^[:space:]]*:[[:space:]]*$/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/:[[:space:]]*$/, "", line)
        cur_path = line
        next
    }
    in_paths && cur_path != "" \
        && /^    (get|post|put|delete|patch|head|options):[[:space:]]*$/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/:[[:space:]]*$/, "", line)
        # POSIX-portable upper-case via tr in a subshell.
        cmd = "printf %s " line " | tr a-z A-Z"
        cmd | getline VERB
        close(cmd)
        print VERB "\t" cur_path
    }
    ' "$OPENAPI_FILE"
)

# 2. Policy rules from gateway-policy-boj.yaml.
#
# Identical extraction to hcg-surface-drift-check.sh so the two scripts
# cannot drift in how they read the policy. Each rule is a
# `- path: "..."` line under `governance.routes:`, followed (on a later
# indented line) by `verbs: [GET, POST, ...]`. Expand the verb list to
# one row per (verb, path).
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

# 3. For each declared route, find a covering policy rule.
#
# Concretise `{name}`-style segments with $PROBE so regex policy paths
# (`^/cartridge/[A-Za-z0-9_.-]+/invoke$` etc.) can be tested against a
# real URL string. The PROBE default ("probe") is shared with the
# smoke and surface-drift scripts so a future tightening of the regex
# character class fails all three checks in lock-step instead of one
# silently.
gap=0
gap_msgs=()
match_msgs=()
while IFS=$'\t' read -r verb tmpl; do
    [ -z "${verb:-}" ] && continue
    # Substitute `{identifier}` segments with the probe placeholder.
    # `{name}` → `probe`, `{cartridge_id}` → `probe`, etc.
    concrete=$(printf '%s' "$tmpl" | sed -E "s|\\{[a-zA-Z_][a-zA-Z0-9_]*\\}|${PROBE}|g")

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
        gap_msgs+=("$verb $tmpl  (concrete: $concrete)")
        gap=$((gap + 1))
    else
        match_msgs+=("$verb $tmpl  →  $matched_rule")
    fi
done <<< "$declared"

echo "==> HCG spec coverage check"
echo "    OpenAPI file: $OPENAPI_FILE"
echo "    Policy file:  $POLICY_FILE"
echo "    Probe placeholder: '$PROBE'"
declared_count=$(printf '%s\n' "$declared" | grep -c . || true)
policy_count=$(printf '%s\n' "$policy" | grep -c . || true)
echo "    Declared (openapi) routes: $declared_count"
echo "    Policy (verb,path) rules:  $policy_count"
echo

if [ "$VERBOSE" = "1" ] && [ ${#match_msgs[@]} -gt 0 ]; then
    echo "Matched:"
    for m in "${match_msgs[@]}"; do
        printf '  %s\n' "$m"
    done
    echo
fi

if [ "$gap" -eq 0 ]; then
    echo "OK: every openapi-declared route is covered by at least one policy rule."
    echo "The §1.5 declared-surface invariant from contract §8 holds; the live"
    echo "policy header's 'Surface source: docs/specification/openapi.yaml,"
    echo "cross-checked against elixir/lib/boj_rest/router.ex' statement is"
    echo "true for the openapi half. (Run hcg-surface-drift-check.sh for the"
    echo "router half.)"
    exit 0
fi

echo "GAP: $gap openapi-declared route(s) are not covered by any policy rule:"
for m in "${gap_msgs[@]}"; do
    printf '  - %s\n' "$m"
done
echo
echo "Resolution: add a matching rule to config/gateway-policy-boj.yaml"
echo "(and config/gateway-policy-boj-example.yaml if the route is part of"
echo "the pedagogical surface). See docs/integration/http-capability-"
echo "gateway-policy-authoring.md §5 for the co-change discipline."
echo "Contract §8 requires governance for declared routes BEFORE they"
echo "are wired in router.ex — otherwise the day they are wired the"
echo "surface-drift gate will fail and traffic that should be live"
echo "default-denies."
exit 1
