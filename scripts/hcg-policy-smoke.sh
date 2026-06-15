#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# hcg-policy-smoke.sh — Exercise the HCG tier-2 live Verb Governance
# Spec from outside the gateway. Returns non-zero on any unexpected
# response, so it can be invoked from the §1.5 / §2.1 prerequisite
# checklist in `docs/integration/hcg-tier2-rollout-runbook.md`.
#
# The default mode probes the *deny* path for every non-public route in
# `config/gateway-policy-boj.yaml` plus a default-deny verb canary for
# DELETE/PUT/PATCH, an exact-status stealth-profile canary that pins
# internal+stealth routes to 404 (vs authenticated routes to 403), and
# an unknown-path no-match canary. The deny path is fully gateway-
# internal — it does not require BoJ to be reachable, so this script
# is the cheapest way to confirm policy enforcement before staging
# cut-over.
#
# With `--with-backend`, the script additionally sends an authenticated
# (or internal) probe per route and asserts the gateway *forwarded* it
# (response did not come from the gateway's own deny path). Allow
# probes require BoJ to be reachable from the gateway's BACKEND_URL,
# and the script itself must run from an IP listed in the gateway's
# `:trusted_proxies` config (loopback by default) so that the
# X-Trust-Level header is not stripped by the gateway's
# `strip_untrusted_headers` plug.
#
# Usage:
#   ./scripts/hcg-policy-smoke.sh --gateway-url http://127.0.0.1:8080
#   ./scripts/hcg-policy-smoke.sh --gateway-url https://stage:8443 \
#       --insecure --with-backend
#
# Exit codes: 0 = all probes matched expectations, 1 = at least one
# mismatch, 64 = bad usage.
#
# Cross-refs:
#   docs/integration/hcg-tier2-rollout-runbook.md   §1.5 / §2.1
#   docs/integration/http-capability-gateway-plan.md §Phase E
#   config/gateway-policy-boj.yaml                  source of truth
#   standards#100                                   tracking issue

set -euo pipefail

GATEWAY_URL=""
WITH_BACKEND=0
INSECURE=0
TRUST_HEADER_NAME="X-Trust-Level"

usage() {
    cat >&2 <<'EOF'
hcg-policy-smoke.sh — Exercise the HCG live policy.

USAGE:
  hcg-policy-smoke.sh --gateway-url URL [--with-backend] [--insecure]
                      [--trust-header NAME]

OPTIONS:
  --gateway-url URL    Base URL of the gateway (required), e.g.
                       http://127.0.0.1:8080 or https://stage:8443.
  --with-backend       Additionally probe the allow path on each route
                       (requires BoJ reachable at the gateway's
                       BACKEND_URL, and this script to run from a
                       trusted-proxy IP).
  --insecure           Pass `-k` to curl (self-signed staging TLS).
  --trust-header NAME  Override the trust-level header name. Defaults
                       to the gateway default `X-Trust-Level`; set this
                       only if `:trust_level_header` was customised.
  -h, --help           Show this help.

EXAMPLES:
  # Deny-only smoke against a local gateway with no BoJ behind it:
  ./scripts/hcg-policy-smoke.sh --gateway-url http://127.0.0.1:8080

  # Full smoke against staging, BoJ up, self-signed TLS:
  ./scripts/hcg-policy-smoke.sh --gateway-url https://stage:8443 \
      --insecure --with-backend

Designed to be run by the operator from the rollout runbook §1.5 last
open item (replacing the out-of-band manual probe sequence) and §2.1
post-stand-up sanity check.
EOF
    exit 64
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gateway-url) GATEWAY_URL="${2:-}"; shift 2 ;;
        --with-backend) WITH_BACKEND=1; shift ;;
        --insecure) INSECURE=1; shift ;;
        --trust-header) TRUST_HEADER_NAME="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

[ -n "$GATEWAY_URL" ] || usage
command -v curl >/dev/null || { echo "curl: not found" >&2; exit 1; }

GATEWAY_URL="${GATEWAY_URL%/}"   # strip trailing slash
CURL_BASE=(curl -sS -o /dev/null -w '%{http_code}' --max-time 10)
[ "$INSECURE" = "1" ] && CURL_BASE+=(-k)

PASS=0
FAIL=0
FAIL_LINES=()

# probe VERB PATH EXPECTED_PATTERN LABEL [trust_level]
#
# EXPECTED_PATTERN is an extended-regex matched against the three-digit
# status code; "deny" expands to 4xx, "allow_or_upstream" expands to
# "anything but a gateway-origin 4xx" (2xx, 3xx, 5xx).
#
# trust_level (optional) is sent as the X-Trust-Level header. Without
# it the gateway treats the caller as untrusted, which is the deny-path
# input.
probe() {
    local verb="$1" path="$2" pattern="$3" label="$4" trust="${5:-}"
    local url="${GATEWAY_URL}${path}"
    local args=("${CURL_BASE[@]}" -X "$verb")
    if [ -n "$trust" ]; then
        args+=(-H "${TRUST_HEADER_NAME}: ${trust}")
    fi
    # Some routes are POST; send an empty JSON body so Plug.Parsers
    # does not 400 on missing content-type.
    if [ "$verb" = "POST" ]; then
        args+=(-H "Content-Type: application/json" --data '{}')
    fi
    args+=("$url")

    local code
    # Quote "${args[@]}" so multi-word array elements (the JSON
    # Content-Type header in particular) stay as single arguments to
    # curl — without quoting, word-splitting turned "Content-Type:
    # application/json" into two args and curl saw "application/json"
    # as a second URL, double-writing %{http_code}.
    code="$("${args[@]}" 2>/dev/null || true)"
    case "$pattern" in
        deny)
            if [[ "$code" =~ ^4[0-9][0-9]$ ]]; then
                printf '  PASS  %-65s %s\n' "$label" "$code"
                PASS=$((PASS + 1))
                return
            fi
            ;;
        allow_or_upstream)
            # The gateway forwarded the request iff the response is NOT
            # a gateway-origin 4xx deny. 2xx/3xx mean BoJ replied;
            # 5xx is upstream-down (also forwarded). The gateway's own
            # circuit-breaker 503 is indistinguishable from an upstream
            # 503 at this level, which is fine — neither indicates a
            # policy regression.
            if [[ ! "$code" =~ ^4[0-9][0-9]$ ]]; then
                printf '  PASS  %-65s %s\n' "$label" "$code"
                PASS=$((PASS + 1))
                return
            fi
            ;;
        [1-5][0-9][0-9])
            # Exact-status pattern — three-digit literal, e.g. 404 or
            # 403. The stealth-profile canary block below uses this to
            # distinguish stealth (404) from plain forbidden (403) on
            # the deny path; the generic `deny` pattern above accepts
            # both, so a regression that demoted a stealth route to
            # 403 would slip through it.
            if [ "$code" = "$pattern" ]; then
                printf '  PASS  %-65s %s\n' "$label" "$code"
                PASS=$((PASS + 1))
                return
            fi
            ;;
    esac
    printf '  FAIL  %-65s %s (expected %s)\n' "$label" "$code" "$pattern"
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("$label  got=$code expected=$pattern")
}

echo "==> HCG policy deny smoke against ${GATEWAY_URL}"
echo "    (config/gateway-policy-boj.yaml; no X-Trust-Level header)"

# Authenticated routes — gateway must 4xx without a trust header.
# Internal+stealth routes — also 4xx (status code shape depends on
# `:stealth_profiles` runtime config; 4xx covers both stealth and
# bare 403).
probe GET  /status                       deny "auth:status-get"
probe GET  /menu                         deny "auth:menu-get"
probe GET  /matrix                       deny "auth:matrix-get"
probe GET  /cartridges                   deny "auth:cartridges-list-get"
probe GET  /cartridge/probe              deny "auth:cartridge-detail-get"
probe POST /cartridge/probe/invoke       deny "auth:cartridge-invoke-post"
probe POST /cartridge/probe/sse          deny "auth:cartridge-sse-post"
probe POST /graphql                      deny "auth:graphql-post"
probe POST /grpc/svc/method              deny "auth:grpc-method-post"
probe GET  /sse                          deny "auth:sse-get"
probe POST /order                        deny "auth:order-post"
probe POST /order-ticket                 deny "auth:order-ticket-post"
probe GET  /umoja/status                 deny "auth:umoja-status-get"
probe GET  /umoja/transport              deny "auth:umoja-transport-get"
probe GET  /umoja/peers                  deny "auth:umoja-peers-get"
probe GET  /coprocessor/status           deny "auth:coprocessor-status-get"
probe GET  /sla/status                   deny "auth:sla-status-get"
probe GET  /community/submissions        deny "auth:community-submissions-get"
probe POST /community/submit             deny "auth:community-submit-post"

probe POST /cartridge/probe/load         deny "internal:cartridge-load-post"
probe POST /cartridge/probe/unload       deny "internal:cartridge-unload-post"
probe POST /cartridge/probe/reload       deny "internal:cartridge-reload-post"
probe POST /umoja/peers                  deny "internal:umoja-peers-post"
probe POST /coprocessor/select           deny "internal:coprocessor-select-post"
probe GET  /sdp/status                   deny "internal:sdp-status-get"

# Default-deny verb canaries — global_verbs is [GET, POST], so any
# DELETE/PUT/PATCH/OPTIONS on a known path must be denied via the
# no-match (or unknown-method) path. Verifies the verb-governance core
# invariant of ADR-0004.
#
# OPTIONS is named in the policy header's banned-verb list and gets its
# own canary because a CORS preflight auto-responder in the gateway
# would silently bypass policy.
#
# Regex-route verb canary (DELETE on cartridge-invoke-post) catches a
# class of bug the exact-path canaries miss: a regression where the
# regex matcher accepts the path under any verb instead of only the
# verb its rule lists.
#
# Wrong-verb-on-listed-path canary (GET on the ssg-mcp webhook, which
# only lists POST) verifies the {path, verb} pairing is enforced: the
# path is in the policy as a public exception, but only for POST; GET
# on the same path must default-deny because no rule covers it.
#
# HEAD is also banned by the policy header but is deliberately not
# canaried here — curl with `-X HEAD` (vs `--head`) waits for a body
# the server will not send, which interacts badly with `--max-time` in
# this script. HEAD enforcement remains covered by the gateway's own
# unit tests; the operator pre-check focuses on probes that survive
# curl's method quirks.
probe DELETE  /cartridges                       deny "verb-canary:DELETE /cartridges"
probe PUT     /health                           deny "verb-canary:PUT /health"
probe PATCH   /cartridges                       deny "verb-canary:PATCH /cartridges"
probe OPTIONS /cartridges                       deny "verb-canary:OPTIONS /cartridges (preflight must not bypass)"
probe DELETE  /cartridge/probe/invoke           deny "verb-canary:DELETE on regex route (cartridge-invoke-post)"
probe GET     /cartridges/ssg-mcp/webhook       deny "verb-canary:GET on POST-only public route (ssg-mcp-webhook-post)"

# Stealth-profile canary — confirms the security property that the deny
# *status code* differs between internal+stealth routes (404, capability
# existence hidden) and authenticated routes (403, capability exists,
# caller lacks credentials). The generic `deny` pattern above accepts
# both, so a misconfiguration where `:stealth_profiles` is not populated
# at runtime would silently demote internal+stealth routes to 403 —
# leaking existence to untrusted callers, the exact threat the
# `sdp-status-get` rule narrative calls out ("not confirmable from
# outside"). The gateway's `handle_denial/3` returns
# `stealth_profiles["default"][trust_str]` for rules with
# `stealth_profile: "default"` and bare 403 otherwise; this canary fixes
# both ends of that switch.
#
# Internal+stealth — exact 404 expected.
probe GET  /sdp/status               404 "stealth-canary:GET /sdp/status (internal+stealth → 404)"
probe POST /cartridge/probe/load     404 "stealth-canary:POST /cartridge/:name/load (internal+stealth → 404)"

# Authenticated, no stealth_profile — exact 403 expected.
probe GET  /status                   403 "stealth-canary:GET /status (authenticated → 403, not stealthed)"
probe GET  /cartridges               403 "stealth-canary:GET /cartridges (authenticated → 403, not stealthed)"

# Unknown-path canary — a synthetic path that matches no exact rule,
# no regex rule, and no public exception. The verb (GET) is in
# `global_verbs`, so this probe isolates the no-match → default-deny
# branch of the gateway's three-tier lookup (exact → regex → global)
# in `lib/http_capability_gateway/gateway.ex` at the `{:error, :no_match}`
# clause. The verb-canaries above exercise the unknown-method path
# (a known path with a verb outside `global_verbs`); this canary
# exercises the unknown-path path (a verb in `global_verbs` against
# a path with no matching rule). Both must default-deny, but the code
# paths are distinct — a regression in either is independently
# possible. The synthetic prefix `__phase-e-canary-` is reserved for
# this probe; it must never appear as a real route in the policy.
probe GET     /__phase-e-canary-unknown-path__ deny "path-canary:GET on synthetic unknown path (no-match default-deny)"

if [ "$WITH_BACKEND" = "1" ]; then
    echo
    echo "==> HCG policy allow smoke (--with-backend)"
    echo "    (X-Trust-Level: authenticated/internal; requires BoJ up)"

    # Authenticated routes — gateway forwards under X-Trust-Level: authenticated.
    # We assert "not a gateway-origin 4xx"; BoJ's own 200/404/500 is fine.
    probe GET  /status                       allow_or_upstream "auth-allow:status-get"               authenticated
    probe GET  /menu                         allow_or_upstream "auth-allow:menu-get"                 authenticated
    probe GET  /cartridges                   allow_or_upstream "auth-allow:cartridges-list-get"      authenticated
    probe GET  /cartridge/probe              allow_or_upstream "auth-allow:cartridge-detail-get"     authenticated
    probe POST /cartridge/probe/invoke       allow_or_upstream "auth-allow:cartridge-invoke-post"    authenticated
    probe POST /cartridge/probe/sse          allow_or_upstream "auth-allow:cartridge-sse-post"       authenticated

    # Public routes — should forward without any trust header.
    probe GET  /health                       allow_or_upstream "public-allow:health-get"             ""
    probe GET  /.well-known/boj-node-pubkey  allow_or_upstream "public-allow:node-pubkey-get"        ""

    # Internal+stealth routes — gateway forwards only under
    # X-Trust-Level: internal.
    probe POST /cartridge/probe/load         allow_or_upstream "internal-allow:cartridge-load-post"  internal
    probe POST /cartridge/probe/unload       allow_or_upstream "internal-allow:cartridge-unload-post" internal
    probe POST /cartridge/probe/reload       allow_or_upstream "internal-allow:cartridge-reload-post" internal
    probe GET  /sdp/status                   allow_or_upstream "internal-allow:sdp-status-get"        internal
fi

echo
echo "────────────────────────────────────────────────────────────────────────"
echo "HCG policy smoke: PASS=${PASS} FAIL=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
    echo
    echo "Mismatches:"
    for line in "${FAIL_LINES[@]}"; do
        echo "  - ${line}"
    done
    echo
    echo "Investigate before flipping the §1.5 checkbox. A 4xx miss on a"
    echo "deny probe means the policy was loaded but is not enforcing as"
    echo "declared; a 4xx on an allow probe means the trust header was"
    echo "stripped (run from a trusted-proxy IP) or BoJ is unreachable."
    exit 1
fi
echo "All probes matched policy. Safe to proceed with §2.1 staging cut-over."
