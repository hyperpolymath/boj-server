<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# http-capability-gateway ↔ BoJ — HTTP Contract

**Version:** 1.0  
**Date:** 2026-05-17  
**Status:** Phase A deliverable A1 (Contract Definition)  
**ADR:** `docs/decisions/0004-adopt-http-capability-gateway.md`  
**Plan:** `docs/integration/http-capability-gateway-plan.md` (Phase A)  
**Audit baseline:** `docs/integration/http-capability-gateway-audit.md`  
**Companion:** `docs/integration/http-capability-gateway-policy-workflow.md` (A2),
`config/gateway-policy-boj-example.yaml` (A3)

---

## Status of this document

This is a **specification** document. It defines the wire contract between
`http-capability-gateway` (the front-end governance layer, tier 2) and BoJ's
unified Zig API gnosis handler (`uapi_gnosis_set_handler`, the back-end, tier 3
and below). Nothing is wired by this document. No gateway or BoJ code changes
in Phase A. The contract here is the input to Phase B (mTLS), Phase C (E2E /
seam tests), and Phase E (production wiring).

Where this document says **MUST** / **MUST NOT** / **SHOULD**, the terms are
used as in RFC 2119. A Phase C seam test (`tests/seam/gateway-boj.test`) is
required to assert every **MUST** in §3 and §4.

---

## 1. Topology

```
client ──TLS──> Cloudflare edge (tier 1)
                     │  (Cloudflare Tunnel, origin hidden — see Trustfile [ORIGIN_PROTECTION])
                     ▼
            http-capability-gateway (tier 2)   ← THIS CONTRACT, front side
                     │  loopback HTTP forward
                     ▼
            BoJ unified Zig API gnosis handler (tier 3)  ← THIS CONTRACT, back side
                     │
                     ▼
            BEAM supervisor / cartridges (tiers 3–4)
```

The gateway terminates the request from the Cloudflare Tunnel, evaluates the
Verb Governance Spec, derives a trust level, and — only for an allowed request
— proxies to the BoJ gnosis handler over a loopback HTTP hop. The gnosis
handler is the single entry point into BoJ's cartridge runtime; it is the
`backend_url` from the gateway's point of view.

---

## 2. Transport and port allocation

### 2.1 Decision (binding for Phase E)

| Environment | Transport | Rationale |
|---|---|---|
| Staging | TCP loopback `http://127.0.0.1:7700` | Simplest; matches the gateway's single `backend_url` config and BoJ's existing REST port (7700, per `docs/specification/openapi.yaml`). No new listener required on the BoJ side. |
| Production | Unix domain socket (preferred) **or** TCP loopback | Unix socket avoids port allocation and is the preferred form for co-located rootless Podman containers (Trustfile `[CONTAINER_SUPPLY_CHAIN]`). Falls back to TCP loopback if the proxy module's Unix-socket support is not landed by Phase E. |

This resolves the Phase A risk *“port / transport indecision”* in the plan:
**staging is TCP loopback on 7700; production targets a Unix socket, with TCP
loopback as the sanctioned fallback.** The gateway's `Proxy` module currently
supports a single TCP `backend_url` (audit §1.5); Unix-socket support is the
only net-new proxy capability this contract requires, and it is explicitly
scoped to Phase E, not Phase A.

### 2.2 Port model

BoJ exposes four protocol surfaces (openapi.yaml `info.description`): REST
7700, gRPC 7701, GraphQL 7702, MCP/SSE 7703. **Phase A scopes the gateway to
the REST surface (7700) only.** The gRPC/GraphQL/SSE surfaces are out of scope
for the initial wiring; placing the gateway in front of them is post-Phase-E
work and is noted as such in the example policy (A3).

The gnosis handler MUST listen for gateway-forwarded traffic on the same port
it serves today (7700). The gateway sits *in front of* that port; BoJ does not
open a second “gateway-only” port. Origin protection (Trustfile
`[ORIGIN_PROTECTION]`) ensures 7700 is reachable only via the Cloudflare
Tunnel and the co-located gateway, never directly from the public internet.

---

## 3. Headers the gateway MUST set on forwarded requests

The gateway's `Proxy` module already sets the first four (audit §1.5). This
contract makes them normative and adds `X-Trust-Level` and `X-Request-ID`.

| Header | Value | Status |
|---|---|---|
| `X-Forwarded-For` | client IP chain | implemented |
| `X-Forwarded-Proto` | `https` | implemented |
| `X-Forwarded-Host` | original `Host` | implemented |
| `X-Gateway` | `http-capability-gateway` | implemented |
| `X-Trust-Level` | exactly one of `untrusted` \| `authenticated` \| `internal` | Phase A defines; Phase B sources it from mTLS |
| `X-Request-ID` | the gateway's `get_request_id/1` output (propagated, not regenerated, if already present from a trusted proxy) | Phase A defines |

### 3.1 `X-Trust-Level` — the central invariant

`X-Trust-Level` is the resolved trust level for the request as decided by the
gateway. It MUST be set from the gateway's compiled trust resolution, **not**
copied from the inbound request.

**Invariant (MUST, tested in Phase C):**

1. The gateway MUST strip any inbound `X-Trust-Level` header from the original
   request unless the immediate sender is in the gateway's `:trusted_proxies`
   list. (This is the gateway's existing `strip_untrusted_headers/2` behaviour;
   audit §4.)
2. The gateway MUST then set `X-Trust-Level` from its own resolution
   (header-based in dev; mTLS-derived in production after Phase B).
3. BoJ's gnosis handler MUST treat `X-Trust-Level` as authoritative **only**
   when the immediate peer is the gateway — i.e. the connection originates from
   `127.0.0.1` (TCP loopback) or the agreed Unix socket / gateway container IP.
   `X-Trust-Level` arriving from any other peer MUST be treated as `untrusted`
   (or the request rejected).
4. BoJ's gnosis handler MUST NOT forward `X-Trust-Level` to cartridge logic
   unchanged. It MUST be consumed (re-validated and mapped to BoJ's internal
   trust representation) or stripped at the gnosis-handler boundary so that no
   cartridge ever reads a caller-supplied trust header.

Header-based trust is forgeable without mTLS; that is exactly why §3.1(1) and
§3.1(3) exist and why production trust derivation moves to mTLS in Phase B.
Until Phase B lands, the loopback-peer check in §3.1(3) is the only thing
standing between a forged `X-Trust-Level` and a cartridge — so it is a **MUST**
from Phase A onward, independent of mTLS.

### 3.2 Trust-level vocabulary

Three values only. They map 1:1 to the gateway's `SafeTrust.parse_trust/1`
(audit §4) and to the `exposure` axis of the Verb Governance Spec:

| `X-Trust-Level` | Gateway atom | Satisfies `exposure` |
|---|---|---|
| `untrusted` | `:untrusted` | `public` |
| `authenticated` | `:authenticated` | `public`, `authenticated` |
| `internal` | `:internal` | `public`, `authenticated`, `internal` |

Denial monotonicity (proved on the gateway side, mirrored from
`proven/SafeTrust.idr`): anything denied at trust level *T* is also denied at
every level lower than *T*. BoJ MUST NOT widen access beyond what the forwarded
`X-Trust-Level` authorises.

---

## 4. Error and failure semantics

| Condition | Gateway behaviour | Status code to client |
|---|---|---|
| Request denied by policy (verb/path/trust) | Do not proxy. Return denial (or stealth response per `stealth` config). | `403`, or the configured stealth status (e.g. `404`) |
| Path/verb not in policy | Default-deny. | `403` / stealth |
| BoJ returns `5xx` | Pass through as `502`. | `502` |
| BoJ unreachable / connection refused | Circuit breaker trips; fail-closed. | `503` |
| Rate limit exceeded (tier 2 token bucket) | Do not proxy. | `429` + `Retry-After` (Trustfile `[CLOUDFLARE_EDGE_SECURITY].rate_limiting.cross_tier`) |

Failure mode for the seam is **fail-closed** — consistent with the
`failure_mode: "fail-closed (circuit breaker)"` value the Phase C seam
declaration will add to Trustfile `[SEAMS]`. The gateway never fails open: a
policy that does not load leaves the last-known-good policy in force (atomic
swap, audit §1.3); a backend that does not answer trips the breaker.

---

## 5. Trusted-proxy configuration (input to Phase B)

The gateway's `:trusted_proxies` default is `["127.0.0.1", "::1"]` (audit §4).
For BoJ:

- **Staging (TCP loopback):** `:trusted_proxies` = `["127.0.0.1", "::1"]`;
  gnosis handler treats only `127.0.0.1`/`::1` as the trusted gateway peer.
- **Production (co-located containers):** the trusted peer is the gateway
  container's address on the pod/container network, or the Unix-socket peer
  credential. The concrete value is a Phase E deployment parameter; Phase B
  must know *which* identity is trusted in order to bind the mTLS client-cert
  decision to it. This contract records the requirement; the value is filled
  in the Phase E rollout runbook.

This is the Phase A → Phase B handoff the plan calls out under *“Blocks: Phase
B requires the Phase A contract to know what the trusted-proxy IP list looks
like.”*

---

## 6. What this contract deliberately does not specify

- **mTLS cert chain / CA selection** — Phase B (`B3` in the plan).
- **Benchmarked latency budget for the extra hop** — Phase D. The ADR's
  indicative `< 2ms median` is not a contract term until Phase D measures it.
- **VeriSimDB audit-trail persistence** — depends on the VeriSimDB stub
  question (audit §4); not a wire-contract concern.
- **gRPC/GraphQL/SSE surfaces** — out of scope; REST 7700 only for initial
  wiring.

---

## 7. Acceptance (Phase A, deliverable A1)

- [x] Transport decided and recorded (§2.1): staging TCP loopback 7700,
      production Unix socket preferred with TCP fallback.
- [x] Port model stated (§2.2): gateway in front of 7700, no second BoJ port.
- [x] Forwarded-header set enumerated, including `X-Trust-Level` and
      `X-Request-ID` (§3).
- [x] `X-Trust-Level` trusted-proxy invariant stated as testable MUSTs (§3.1)
      — handed to Phase C as seam-test obligations.
- [x] Error/circuit-breaker semantics stated (§4).
- [x] Trusted-proxy requirement handed to Phase B (§5).
- [x] No gateway or BoJ code changed.
