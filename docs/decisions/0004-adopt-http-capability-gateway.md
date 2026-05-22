<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# 4. Adopt http-capability-gateway as BoJ Tier-2 HTTP Governance Layer

Date: 2026-04-17

## Status

Accepted

## Context

BoJ's HTTP surface today terminates at the unified Zig API gnosis handler
(`uapi_gnosis_set_handler`), introduced in the single-port consolidation
(commits `9c807c0`, `d765345`). This means:

1. **Verb governance is absent at the HTTP layer.** There is no single location
   declaring which HTTP verbs are permitted on which paths. Any cartridge that
   handles a route implicitly accepts all verbs Cowboy routes to it. DELETE, PUT,
   PATCH, OPTIONS, and HEAD can be accessible without explicit intent.

2. **Rate-limiting logic is fragmented.** The four-tier rate-limit architecture
   documented in `Trustfile.a2ml [CLOUDFLARE_EDGE_SECURITY].rate_limiting` has a
   declared gap at tier 2 (`status: "PENDING — http-capability-gateway wiring
   forthcoming"`). Tiers 1 (Cloudflare edge) and 3–4 (BEAM supervisor, cartridge
   manifest) are in place; tier 2 is empty.

3. **Capability-enforcement logic is either in the gnosis handler (too low-level)
   or distributed across cartridges (too distributed, no central policy).** There is
   no central, auditable declaration of what the HTTP surface exposes at what trust level.

4. **Trust-level derivation has no primary path.** The Trustfile's `[SDP_RULES]`
   and `[ORIGIN_PROTECTION]` sections imply mutual TLS and trust-level-aware routing,
   but no component in the current stack derives, validates, or forwards a trust level
   on incoming HTTP requests before they reach cartridge logic.

The estate has independently built `hyperpolymath/http-capability-gateway` as a
general HTTP governance layer. An audit conducted 2026-04-17 (see
`docs/integration/http-capability-gateway-audit.md`) confirmed:

- The core policy pipeline (loader → validator → compiler → ETS enforcement → proxy →
  telemetry) is implemented and working.
- DSL v1 (Verb Governance Spec) is defined and validated.
- The gateway is Elixir/Cowboy/Plug — architecturally compatible with BoJ's BEAM stack.
- Stated gaps (mTLS as primary path, E2E verification, benchmark evidence) are real
  and must be closed before production deployment. Estimated 8–12 weeks of focused work.
- Tier 2 placement (between Cloudflare edge and BoJ's gnosis handler) is
  architecturally sound. No conflict with Svalinn (container gateway) or the BEAM
  supervisor tier.

## Decision

Adopt `http-capability-gateway` as **tier 2 of BoJ's rate-limit and capability-enforcement
architecture** (filling the `PENDING` gap in `Trustfile.a2ml [CLOUDFLARE_EDGE_SECURITY]
.rate_limiting.tier_2_gateway`).

The integration is structured in five phases:

| Phase | Scope | Weeks |
|---|---|---|
| A | Contract definition, policy authoring workflow, example Verb Governance Spec | 1–2 |
| B | mTLS as primary trust-level path, Cowboy TLS config, real-CA test fixture | 3–5 |
| C | E2E verification tests, seam test across gateway ↔ gnosis handler boundary | 5–7 |
| D | Benchmark formalisation, latency numbers published, CI regression alert | 7–8 |
| E | Production wiring, staging validation, rollout, rollback runbook | 8–12 |

Phase 0 (today, 2026-04-17) is the audit and planning session. No code changes to
the gateway or to BoJ's HTTP surface are made in Phase 0.

Full phase detail in `docs/integration/http-capability-gateway-plan.md`.

## Consequences

### Positive

- **Declarative HTTP governance.** All permitted verbs, their trust requirements, and
  their narrative rationale are declared in a single version-controlled YAML file
  (the Verb Governance Spec). Any change to BoJ's HTTP surface must be reflected there.

- **Verb-level enforcement before cartridges.** The gateway enforces verb governance
  at the HTTP layer before any cartridge logic runs. Cartridges receive only requests
  that have already passed policy evaluation. Cartridges no longer need to defend
  against unexpected HTTP verbs.

- **Trust-level derivation centralised.** After Phase B, the gateway derives trust
  level from mTLS client certificates and forwards it as `X-Trust-Level` to the
  gnosis handler. Cartridges consume a pre-validated trust level; they do not need
  to extract or validate it themselves.

- **Fills tier-2 gap in rate-limit architecture.** The per-IP token-bucket rate
  limiter (10/s untrusted, 100/s authenticated, unlimited internal) closes the
  gap between Cloudflare edge rate limits (tier 1) and BEAM supervisor back-pressure
  (tier 3).

- **Audit trail.** Every access decision (allow/deny, path, verb, trust level, rule
  name, duration) is logged in structured JSON and optionally persisted to VeriSimDB.
  This provides an auditable record of all HTTP surface access.

- **Decouples edge from governance.** Cloudflare (tier 1) and the gateway (tier 2)
  are independent components that can evolve separately. Cloudflare handles volumetric
  DDoS; the gateway handles verb governance and trust-level enforcement. If Cloudflare
  is bypassed (e.g., direct access to origin via Fly.io), the gateway still enforces
  policy.

- **Stealth mode.** Routes with `exposure: "internal"` can return 404 (or any
  configurable status) instead of 403, hiding capability existence from unprivileged
  callers.

### Negative

- **One more component in the stack.** The gateway adds operational complexity:
  a new container to deploy, configure, monitor, and update. Containerfile, k9-svc
  deployment spec, cert rotation runbook, and rollback runbook must all be maintained.

- **Gateway is Elixir — adds a second BEAM application.** BoJ is multi-language
  (Idris2 ABI, Zig FFI, Elixir runtime), but the gateway is a separate Elixir
  application that must be supervised and monitored independently. The BEAM handles
  this well, but operational burden increases.

- **Compile-then-load policy model requires hot-reload to be first-class.** The atomic
  swap pattern is implemented, but any BoJ HTTP surface change must be reflected in
  the policy file and reloaded. If the policy file lags the actual surface, routes
  may be default-denied. Phase A must define the policy authoring workflow clearly.

- **Latency overhead.** The gateway adds a hop in the request path. Benchmark evidence
  (Phase D) will quantify this. Initial estimate based on ETS O(1) lookup + Req HTTP
  proxy: < 2ms median overhead for a 100-rule policy. This must be confirmed.

### Risks

- **mTLS gaps must close before production.** The mTLS trust-extraction path in the
  gateway is coded but not the primary proved path (see audit §4). Header-based trust
  is forgeable without mTLS enforcement. Production deployment (Phase E) must wait
  for Phase B completion.

- **Single-backend proxy.** The gateway's proxy module supports one `backend_url`.
  If BoJ is horizontally scaled, the gateway must sit behind a load balancer, or the
  proxy module must be extended. This is noted as post-Phase-E work.

- **VeriSimDB integration unconfirmed.** The audit could not confirm whether the
  gateway's `VeriSimDB` module is a real integration or a thin stub. The audit trail
  depends on this. Phase E should not be completed until VeriSimDB status is confirmed.

### Tier placement note

The audit confirms that tier 2 (between Cloudflare edge and BoJ's gnosis handler)
is the correct placement. An alternative would be to place the gateway alongside tier 3
(BEAM supervisor), where it would run co-located with the BoJ Elixir process rather
than in front of the gnosis handler. This would be wrong: the gateway's role is to
govern the HTTP surface before it reaches any BoJ component, not to provide another
enforcement layer inside BoJ. Tier 2 placement is confirmed.

## Related

- ADR 0002 (`docs/decisions/0002-align-unified-zig-api-stack.md`) — unified Zig API
  stack (the gnosis handler the gateway sits in front of).
- ADR 0003 (`docs/decisions/0003-extract-cartridge-spec-standalone.md`) — cartridge
  specification (verb governance per cartridge is the downstream beneficiary of this ADR).
- Trustfile `[HTTP_CAPABILITY_GATEWAY]` section (commit `ceae54c`) — forward-reference
  entry updated in this session to `status: "ACCEPTED-PLANNED"`.
- Trustfile `[CLOUDFLARE_EDGE_SECURITY].rate_limiting.tier_2_gateway` — the gap this ADR closes.
- `docs/integration/http-capability-gateway-audit.md` — audit conducted 2026-04-17.
- `docs/integration/http-capability-gateway-plan.md` — phased integration plan.
