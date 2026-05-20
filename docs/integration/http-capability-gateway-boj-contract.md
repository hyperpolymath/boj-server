<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# http-capability-gateway ↔ BoJ — HTTP Contract

**Version:** 1.0
**Date:** 2026-05-18
**Status:** Phase A deliverable A1 (normative for Phases B–E)
**ADR:** `docs/decisions/0004-adopt-http-capability-gateway.md`
**Plan:** `docs/integration/http-capability-gateway-plan.md` (§ Phase A, A1)
**Audit baseline:** `docs/integration/http-capability-gateway-audit.md` (2026-04-17)
**Tracking:** standards#91 (parent), standards#96 (Phase A)

> **File-format note.** This document and its sibling
> (`http-capability-gateway-policy-authoring.md`) are kept as `.md`, not
> `.adoc`, deliberately: the integration plan normatively prescribes the path
> `docs/integration/http-capability-gateway-boj-contract.md`, the Phase C
> Trustfile `[SEAMS]` entry will reference that exact path, and the entire
> `docs/integration/` + `docs/decisions/` doc-set is Markdown. Faithfulness to
> the normatively-referenced path outweighs the estate `.adoc` default here.

---

## 0. Scope

This contract defines the **exact HTTP boundary** between the front component
(`hyperpolymath/http-capability-gateway`, tier 2) and the back component (BoJ's
unified Zig API gnosis handler, fronted by `BojRest.Router`, tier 3). It is the
authoritative seam description. No code is wired in Phase A; this document
governs Phases B–E and is the contract the Phase C seam test must satisfy.

The gateway sits **between** Cloudflare edge (tier 1) and BoJ's gnosis handler.
It enforces verb governance, trust-level derivation, stealth, and audit logging
on every request **before** any BoJ cartridge logic runs.

---

## 1. Transport

| Aspect | Staging | Production |
|---|---|---|
| Gateway → BoJ transport | **TCP loopback** | **Unix domain socket** |
| Rationale | Simpler; matches the gateway's single `backend_url` config; no socket plumbing needed for first bring-up. | Avoids port allocation, removes the loopback TCP attack surface, and is the preferred path for co-located Podman containers sharing a pod network namespace. |

**Decision (committed, per plan risk "Port / transport indecision"):**

- **Staging:** gateway `BACKEND_URL=http://127.0.0.1:7700` → BoJ gnosis handler
  listens on loopback `:7700` for gateway-forwarded traffic. The externally
  visible port is owned by the gateway (8443 TLS / 8080 HTTP-behind-Tunnel);
  BoJ's `:7700` is **not** externally routable.
- **Production:** gateway `BACKEND_URL=http://unix:/run/boj/gnosis.sock:/` (or
  the gateway's documented Unix-socket backend form). BoJ binds the gnosis
  handler to `/run/boj/gnosis.sock`, mode `0660`, owned by the shared pod user.
  No TCP port is opened for the back side in production.

The gateway proxy module currently supports a single `backend_url`; both forms
above are single-backend and within its current capability. Horizontal scaling
of BoJ (multi-backend) is explicitly **out of scope** for this contract and is
recorded as post-Phase-E work in the plan.

---

## 2. Headers the gateway MUST set on forwarded requests

| Header | Value | Status |
|---|---|---|
| `X-Forwarded-For` | original client IP | already implemented (Proxy module) |
| `X-Forwarded-Proto` | `https` / `http` | already implemented |
| `X-Forwarded-Host` | original `Host` | already implemented |
| `X-Gateway` | `http-capability-gateway` | already implemented |
| `X-Request-ID` | gateway `get_request_id/1` output | propagate; BoJ logs it |
| `X-Trust-Level` | `untrusted` \| `authenticated` \| `internal` | **see §3 — security-critical** |

Notes:

- `X-Request-ID` MUST be propagated end-to-end so the gateway audit record and
  BoJ's structured log line share a correlation key.
- The gateway's resolved trust vocabulary is `untrusted | authenticated |
  internal`. BoJ's `BojRest.TrustPolicy` consumes `internal | authenticated`
  as "credentialed" and treats `untrusted`/absent as "public only" (see
  `BojRest.Router` moduledoc and `docs/AUTH-DESIGN.adoc`). The gateway's
  `untrusted` maps to BoJ's "public" tier. This vocabulary mapping is fixed by
  this contract:

  | Gateway `X-Trust-Level` | BoJ trust class |
  |---|---|
  | `internal` | internal (credentialed; lifecycle/admin) |
  | `authenticated` | authenticated (credentialed) |
  | `untrusted` / absent | public (only `auth.method: "none"` cartridges) |

---

## 3. Trust-header security invariant (load-bearing)

`BojRest.Router` **bypasses trust enforcement entirely for loopback callers**
(`loopback?(conn.remote_ip)` → enforcement skipped; local dev / mcp-bridge
path). In staging the gateway forwards from `127.0.0.1`; in production it
forwards over a loopback Unix socket. **Therefore BoJ will treat the gateway as
a fully trusted proxy and accept its `X-Trust-Level` verbatim.**

This makes the following invariant **mandatory, not advisory**:

1. The gateway MUST **strip any inbound `X-Trust-Level`** from the original
   client request unless the immediate peer is in the gateway's
   `:trusted_proxies` allow-list. A client-supplied `X-Trust-Level` MUST NEVER
   survive into the forwarded request.
2. The gateway MUST **re-set `X-Trust-Level`** from its own resolved trust
   decision (header-based pre-Phase-B; mTLS client-cert-derived from Phase B
   onward) before forwarding.
3. BoJ's gnosis handler / `BojRest.Router` MUST treat `X-Trust-Level` as
   authoritative **only** when the connection originates from the gateway
   (loopback `127.0.0.1` in staging; the loopback Unix socket in production).
   Any `X-Trust-Level` arriving from any other source MUST be ignored and
   treated as `untrusted`.
4. The back-side bind (BoJ `:7700` / `/run/boj/gnosis.sock`) MUST NOT be
   externally routable. If it were, an attacker reaching it directly would
   inherit loopback trust-bypass. Network/socket isolation of the back side is
   part of this contract, not an operational nicety.

Failure to honour (1)–(4) is a trust-forgery vulnerability: a forged
`X-Trust-Level: internal` from an external client would reach a loopback-trusting
router. This invariant is tested in Phase C (plan §Phase C, "Trust header
forwarding security invariant") and hardened in Phase B (mTLS becomes the
trust source so the resolved value cannot be header-forged at all).

**Implementation status (Phase C):**

- Gateway-side (1)+(2): `http-capability-gateway/lib/http_capability_gateway/proxy.ex`
  `build_backend_headers/1` strips client-supplied `X-Trust-Level` + `X-Request-ID`
  and re-emits the gateway-resolved values. Landed in http-capability-gateway#11.
- BoJ-side (3): `boj_rest/lib/boj_rest/trust_policy.ex` `satisfies?/3` ignores
  the header for any non-loopback caller via the
  `satisfies?(_required, _trust, false), do: false` clause — defence in depth
  against (4) being violated by a misconfiguration. Verified by
  `elixir/test/phase_c_seam_test.exs` (9 tests, all live).
- (4) is an operational/configuration invariant, not a code change; verified
  during Phase E rollout (production deployments MUST front BoJ with a
  loopback-only socket per the §Phase E runbook).

---

## 4. Headers BoJ MUST NOT forward to cartridges unchanged

- `X-Trust-Level` MUST be consumed and re-validated by `BojRest.TrustPolicy` at
  the router boundary and MUST NOT be passed opaquely into cartridge invocation
  arguments. Cartridges receive a *decision* (allowed/denied + trust class),
  never the raw transport header, so a cartridge cannot be tricked by a header
  it was never meant to interpret.
- `X-Node-Identity`, when present, is **logged for audit** by the router but is
  not an authorization input and MUST NOT be promoted to a trust signal.

---

## 5. Error semantics

| Condition | Gateway response | Notes |
|---|---|---|
| BoJ returns 5xx (e.g. `invocation-failed` 500) | **502 Bad Gateway** | existing gateway behaviour; the upstream 500 body is not leaked verbatim |
| BoJ unreachable / connection refused | circuit breaker trips → **503 Service Unavailable** | fail-closed; matches Trustfile `[SEAMS]` `failure_mode: "fail-closed (circuit breaker)"` |
| Verb not permitted by policy | **403** (or stealth status, see §6) | decision made at gateway; request never reaches BoJ |
| Path not in policy | **default-deny** (403 / stealth) | unlisted path ⇒ denied; request never reaches BoJ |
| BoJ returns 4xx (e.g. `unknown-cartridge` 404, `forbidden` 403) | **passed through unchanged** | these are legitimate application responses, not gateway faults |

The circuit-breaker fail-closed posture means a gateway↔BoJ seam failure denies
traffic rather than failing open — consistent with the ADR's "fail-closed"
stance and the rate-limit architecture's defence-in-depth intent.

---

## 6. Stealth

Routes declared `exposure: "internal"` with a stealth profile return the
configured stealth status (default **404**) instead of **403** to callers below
the required trust level, hiding capability existence. The example policy
(`config/gateway-policy-boj-example.yaml`) enables `stealth: { enabled: true,
status_code: 404 }` and applies it to lifecycle/admin/SDP routes (§ A3).

---

## 7. Deployment trust topology (input to Phase B)

Phase B (mTLS) needs the trusted-proxy / loopback topology fixed here:

- **Staging:** gateway and BoJ co-located; gateway → BoJ over loopback TCP
  `127.0.0.1:7700`. Gateway `:trusted_proxies` = `["127.0.0.1"]`. Trust source
  `"header"`.
- **Production:** gateway → BoJ over loopback Unix socket. The mTLS boundary is
  **client → gateway** (the externally facing edge); the gateway → BoJ hop is
  loopback-isolated and does not itself require mTLS. The CA / cert-rotation
  decisions for the client→gateway mTLS boundary are Phase B (B3).

---

## 8. Surface drift caveat (input to A3)

`BojRest.Router` today implements a **subset** of `docs/specification/openapi.yaml`
(`/.well-known/boj-node-pubkey`, `/health`, `/menu`, `/cartridges`,
`/cartridge/:name`, `/cartridge/:name/invoke`; everything else falls to the
`match _` → 404 catch-all). `openapi.yaml` declares a broader surface
(`/status`, `/matrix`, `/graphql`, cartridge `load|unload|reload`, `/grpc/*`,
`/sse`, `/order`, `/order-ticket`, `/umoja/*`, `/coprocessor/*`, `/sla/status`,
`/community/*`, `/sdp/status`, `/cartridges/ssg-mcp/webhook`).

**Contract decision:** the Verb Governance Spec governs the **declared**
surface (`openapi.yaml`), not only the currently-wired subset. Declared-but-
unimplemented routes are still classified in the policy so that when the gnosis
handler grows them they are governed from day one rather than silently exposed.
The gateway's default-deny for any *undeclared* path remains the backstop. This
resolves the plan's "Surface drift" risk for Phase A: the example policy is
authored from `openapi.yaml` cross-checked against `router.ex`, with every
divergence annotated in the policy `narrative` fields.
