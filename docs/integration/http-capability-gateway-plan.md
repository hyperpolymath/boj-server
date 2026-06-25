<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# http-capability-gateway — BoJ Integration Plan

**Version:** 1.0  
**Date:** 2026-04-17  
**Status:** Active (Phase 0 complete — audit + plan landed)  
**Companion audit:** `docs/integration/http-capability-gateway-audit.md`  
**ADR:** `docs/decisions/0004-adopt-http-capability-gateway.md`  
**Timeline:** ~8–12 weeks total across Phases A–E.

---

## Overview

This document is the authoritative integration plan for wiring `http-capability-gateway`
into BoJ as tier-2 of the rate-limit + capability-enforcement architecture. It is
normative: each phase has declared deliverables, acceptance criteria, risks, and
blocking relationships. Phases are ordered by dependency; Phases A and B may overlap
once the Phase A contract spec is stable.

The gateway sits between the Cloudflare edge (tier 1) and BoJ's unified Zig API
gnosis handler (tier 3 and below). It adds declarative verb governance, trust-level
enforcement, stealth profiles, and structured audit logging to the HTTP surface without
modifying any BoJ cartridge logic.

**Current HTTP surface reference:** `docs/specification/openapi.yaml`.  
**BoJ gnosis handler entry point:** `uapi_gnosis_set_handler` in the unified-zig-api
stack (commits `9c807c0`, `d765345` — single-port consolidation).

---

## Phase A — Contract Definition (weeks 1–2)

### Objective

Define the exact HTTP contract between the gateway (front) and BoJ's unified Zig API
gnosis handler (back), and establish the Verb Governance Spec authoring workflow.
Nothing is wired in this phase; the output is specification documents and an example
policy file.

### Deliverables

**A1 — Gateway↔BoJ HTTP contract document**

File: `docs/integration/http-capability-gateway-boj-contract.md`

Must specify:
- Transport: whether the gateway forwards to BoJ via TCP localhost or Unix socket.
  Decision rationale: TCP localhost is simpler and matches the gateway's single
  `backend_url` config; Unix socket avoids port allocation and is preferred for
  co-located Podman containers. Recommend TCP localhost for staging, Unix socket
  for production.
- Port allocation: if TCP, which port does BoJ's gnosis handler listen on for
  gateway-forwarded traffic (separate from the externally visible port, or same port
  with gateway sitting in front).
- Headers the gateway MUST set on forwarded requests:
  - `X-Forwarded-For` (already implemented in Proxy module).
  - `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Gateway: http-capability-gateway`
    (already implemented).
  - `X-Trust-Level: {authenticated|internal|untrusted}` — trust level as resolved
    by the gateway, stripped from the original request and re-set from the compiled
    trust value. BoJ's gnosis handler MUST accept this header from `127.0.0.1`
    (trusted proxy).
  - `X-Request-ID` — propagated from the gateway's `get_request_id/1` output.
- Headers BoJ's gnosis handler MUST NOT forward to cartridges unchanged:
  - `X-Trust-Level` must be re-validated or stripped before reaching cartridge logic.
- Error semantics: if BoJ returns 500, gateway returns 502 (existing behaviour).
  If BoJ is not reachable, circuit breaker trips and gateway returns 503.

**A2 — Verb Governance Spec authoring workflow**

Answers:
- Where does the Verb Governance Spec YAML live? Options:
  1. In the `boj-server` repo at `config/gateway-policy.yaml`, loaded at gateway
     startup from a mounted path.
  2. As a separate file in `web-ecosystem/http-capability-gateway/config/boj-policy.yaml`.
  Recommendation: option 1 — the policy describes BoJ's HTTP surface, so it belongs
  in the BoJ repo and is version-controlled alongside `docs/specification/openapi.yaml`.
- Who writes it? BoJ maintainer, reviewed like any spec change.
- How is it loaded at deploy? Via `POLICY_PATH` environment variable in the gateway
  container; the file is mounted from a ConfigMap or bind-mount at that path.
- Hot-reload: the gateway's atomic swap pattern supports SIGHUP-triggered reload.
  Document the reload trigger mechanism (k9-svc rolling deploy, or a separate
  `gateway-reload` signal).

**A3 — Example Verb Governance Spec for BoJ**

File: `config/gateway-policy-boj-example.yaml` (in boj-server repo)

Derived from `docs/specification/openapi.yaml`. Must cover:
- `/health` → GET, public.
- `/ready` (if BoJ exposes it) → GET, public.
- `/cartridges` → GET (authenticated), POST (internal).
- `/cartridges/{id}` → GET (authenticated), DELETE (internal).
- `/cartridges/{id}/invoke` → POST (authenticated).
- `/admin` and sub-paths → GET, internal only, stealth: 404.
- GraphQL port and gRPC port paths (if gateway is also placed in front of those surfaces).

### Acceptance Criteria

- Contract document exists and is reviewed.
- Verb Governance Spec workflow is documented.
- Example policy file passes `PolicyLoader.load_policy/1` + `PolicyValidator.validate/1`
  when run against the gateway (manual verification).
- No code changes to gateway or BoJ gnosis handler.

### Risks

- **Port / transport indecision:** If TCP vs. Unix socket is not decided in Phase A,
  Phase E deployment will be blocked. Decide in A1 and commit.
- **Surface drift:** `openapi.yaml` may not reflect actual gnosis handler routes
  (it was accurate at audit time but may lag). Cross-check against the Zig API
  source before authoring the example policy.

### Blocks

Phase B (mTLS) requires the Phase A contract to know what the trusted-proxy IP
list looks like in deployment (loopback, container network, etc.).

---

## Phase B — mTLS Primary Path (weeks 3–5)

### Objective

Move the gateway's trust-level extraction from header-based (`X-Trust-Level`) to
mTLS client certificate validation. The header path remains available for development;
mTLS becomes the production path. The gateway SHOULD reject non-mutual-TLS traffic
(or demote it to `untrusted`) at the transport layer.

### Deliverables

**B1 — Cowboy TLS configuration with `verify: :verify_peer`**

The gateway's `application.ex` / `config/prod.exs` must configure Cowboy TLS with:
```elixir
{:tls_options, [
  verify: :verify_peer,
  fail_if_no_peer_cert: true,
  cacertfile: System.get_env("MTLS_CA_CERT_PATH"),
  certfile: System.get_env("GATEWAY_CERT_PATH"),
  keyfile: System.get_env("GATEWAY_KEY_PATH")
]}
```

**B2 — `is_cert_verified/1` reads actual TLS state**

The current stub (`is_cert_verified/1` returns `true` if a cert is present) must be
replaced with a function that reads the actual peer verification result from Cowboy.
In Cowboy 2.x: `cowboy_req:peercert/1` combined with `:ssl.connection_information/2`
or checking the verify result stored in the SSL socket. The exact mechanism must be
confirmed against Cowboy 2.7 API documentation.

**B3 — CA selection and cert rotation policy**

Decide whether the mTLS CA is:
1. BoJ's own CA (generated at deploy time, self-signed root).
2. The estate's SDP CA (if one exists).
3. Cloudflare Origin CA (for authenticated origin pull parity).

Authenticated Origin Pulls parity: the gateway SHOULD be configured to reject
connections that do not present a valid client cert from the chosen CA. This mirrors
the Cloudflare AOP model at the gateway level.

Cert rotation runbook: documented in `docs/integration/mtls-rotation-runbook.md`.
Runbook must cover: cert generation, distribution to gateway and BoJ containers,
hot-reload without downtime.

**B4 — Idris2 proof obligation recorded**

File: `src/abi/` or `PROOFS_NEEDED.md` update.

The mTLS policy decision (cert chain rooted in chosen CA → "internal" trust) must
have a proof obligation recorded. The proof does not have to land in Phase B, but:
- The claim must be stated in Idris2 terms.
- The proof file path must be declared (e.g., `src/abi/Trust.MTLSPolicy.idr`).
- The proof is listed in `PROOFS_NEEDED.md` with status "pending Phase C/D".

### Acceptance Criteria

- Gateway compiled and tested with Cowboy `verify: :verify_peer`.
- `is_cert_verified/1` reads real TLS verification state (not just cert presence).
- `test/security_test.exs` includes a test using a real test CA fixture (not a
  real production CA — a self-signed test CA generated with `openssl req`).
- Gateway refuses connections with no client cert when `:trust_level_source` is `"mtls"`.
  (Tests this: send a request with no cert; verify response is 403 or connection
  refused, depending on the `fail_if_no_peer_cert` config.)
- Idris2 proof obligation for mTLS policy recorded.
- Cert rotation runbook written.

### Risks

- **Cowboy 2.7 API changes:** The mTLS peer-verify API may differ from earlier
  Cowboy versions. Verify against `plug_cowboy ~> 2.7` docs before coding.
- **Test fixture complexity:** Generating test CA + client certs in `mix test` is
  non-trivial. Consider using `:public_key.pkix_sign/2` to generate in-memory certs
  for unit tests, and a shell script for integration test fixtures.
- **SDP CA dependency:** If using the estate SDP CA, the CA must exist before Phase B
  can start. If no SDP CA exists, create BoJ's own CA in this phase.

### Blocks

Phase C (E2E tests) depends on Phase B mTLS being operational (E2E tests should
exercise both the header path and the mTLS path).

---

## Phase C — End-to-End Verification (weeks 5–7)

### Objective

Write end-to-end tests that prove the complete pipeline: Verb Governance Spec file
→ compiled rules → gateway enforces → BoJ gnosis handler receives only allowed traffic.
Seam test: the gateway ↔ BoJ boundary must be exercised with a contract matching the
Phase A contract document.

### Deliverables

**C1 — E2E test suite for gateway ↔ BoJ seam**

File: `test/e2e_boj_integration_test.exs` (in the gateway repo)

or

File: `tests/seam/gateway-boj.test` (in boj-server repo, matching the SEAMS-SPEC format)

Must cover:
- A request that matches a `public` rule → BoJ receives the request with
  `X-Trust-Level: untrusted`, responds, gateway returns the response.
- A request that matches an `authenticated` rule with `X-Trust-Level: authenticated`
  (header path) → allowed.
- A request that matches an `authenticated` rule with `X-Trust-Level: untrusted`
  → gateway returns 403 (or stealth response).
- A request that matches an `internal` rule with no cert / wrong trust → denied.
- A verb not in the policy → denied.
- A path not in the policy → default-deny.
- Policy hot-reload: load policy A, verify enforcement, reload policy B, verify new
  enforcement without dropped requests.

**C2 — Property tests for the pipeline**

File: `test/e2e_property_test.exs` (gateway repo)

StreamData properties:
- For any policy that loads and validates successfully, `compile/2` succeeds and
  `lookup/3` never returns `{:ok, rule}` for a verb not declared in the policy.
- For any path+verb denied under trust level T, it is also denied under any T' < T
  (monotonicity of denial preserved through the full pipeline).

**C3 — Seam declaration in BoJ Trustfile**

Add to `[SEAMS]` in `Trustfile.a2ml`:

```yaml
- id: "gateway-boj-gnosis"
  description: "http-capability-gateway ↔ BoJ unified Zig API gnosis handler"
  from: "web-ecosystem/http-capability-gateway"
  to: "src/zig-api/ (gnosis handler)"
  contract: "docs/integration/http-capability-gateway-boj-contract.md"
  test_ref: "tests/seam/gateway-boj.test"
  failure_mode: "fail-closed (circuit breaker)"
  tier: "elixir-disciplined"
```

### Acceptance Criteria

- E2E tests pass in CI (not just locally).
- Coverage threshold: all six cases in C1 have passing tests.
- Seam test (C1) exercises the HTTP contract from Phase A: headers set correctly,
  trust level forwarded, response returned to caller.
- Property tests (C2) pass with at least 200 samples.
- Seam declared in Trustfile.

### Risks

- **Test environment isolation:** E2E tests require a running BoJ instance. Options:
  1. Mock backend (easiest — Bypass module in the gateway test suite).
  2. Real BoJ in CI (preferred for seam test — more complex setup).
  Use mock backend for C1/C2 in Phase C; schedule real BoJ seam test for Phase E.
- **Policy hot-reload under load:** The existing `concurrency_test.exs` covers
  gateway-internal reload. The BoJ seam test must also verify that in-flight
  requests are not dropped during a reload. This is the most complex test to write.

### Blocks

Phase D benchmarks depend on Phase C tests establishing a baseline measurement
environment.

---

## Phase D — Benchmarks (weeks 7–8)

### Objective

Formalise the "fast policy enforcement" claim with published latency numbers. Define
the load profile, run the benchmark suite, and configure a regression alert so that
future changes that degrade gateway performance are caught in CI.

### Deliverables

**D1 — Load profile declaration**

Document in `docs/integration/gateway-load-profile.md`:
- Baseline: requests/second the BoJ gnosis handler receives in production today.
- Gateway load profile: same request rate + gateway overhead should be < declared limit.
- Measurement environment: hardware spec, Elixir/OTP version, policy size (number of rules).

**D2 — Benchmark results published**

The existing `test/benchmark_test.exs` covers:
- Rate limiter throughput.
- Circuit breaker state transition cost.
- Exact vs. regex vs. global-fallback route lookup.

Extend benchmarks to measure:
- **Median / p95 / p99 request-to-response latency** through the full Plug pipeline
  (security headers → strip → extract trust → rate limit → policy lookup → proxy
  response) under the declared load profile.
- Comparison baseline: latency of the same request hitting BoJ directly (no gateway).
- **Gateway overhead** = gateway median latency − baseline median latency.

Target: gateway overhead < 2ms median, < 5ms p99 for a policy with 100 rules
(indicative — revisit once baseline is measured).

**D3 — Regression alert in CI**

Add a CI step that runs the benchmark suite and fails if the measured p99 latency
exceeds a declared threshold (initially generous — tighten after a few builds
establish a stable baseline). The benchmark step should be gated (not run on every
PR; run on merge to main and weekly schedule).

### Acceptance Criteria

- Load profile document exists.
- Median / p95 / p99 latency numbers published in `docs/integration/gateway-benchmarks.md`.
- Gateway overhead number published (vs. direct BoJ, no gateway).
- CI regression step configured.
- Benchmark results do NOT fabricate numbers — they come from a `mix bench` or
  `mix test --only benchmark` run against the real hardware or a representative CI runner.

### Risks

- **CI hardware variability:** Benchmark numbers from GitHub Actions runners vary
  significantly run-to-run. Use relative measurements (gateway overhead fraction)
  rather than absolute numbers for regression detection.
- **Policy size sensitivity:** A policy with 5 rules will perform differently than
  one with 500 rules. The benchmark must test the realistic BoJ policy size.

### Blocks

Phase E production deployment requires D3 (regression alert) to be in place before
rollout.

---

## Phase E — Production Wiring (weeks 8–12)

### Objective

Deploy http-capability-gateway in front of BoJ in staging, verify all telemetry and
logging are correct, then roll out to production. Demonstrate end-to-end traffic
handling under real load.

### Deliverables

**E1 — Containerfile and deployment spec for the gateway**

The gateway already has a `Containerfile`. Confirm it:
- Uses a Chainguard base image.
- Accepts `POLICY_PATH`, `BACKEND_URL`, `PORT`, `MTLS_CA_CERT_PATH` env vars.
- Is built with Podman (rootless).
- Is signed as a `.ctp` bundle via cerro-torre.

Add a k9-svc deployment spec at `container/gateway-deploy.k9.ncl` in the gateway repo.

**E2 — Staging deployment**

Deploy the gateway in front of a BoJ staging instance:
- Gateway listens on port 8443 (TLS) or 8080 (HTTP, behind Cloudflare Tunnel).
- Backend: BoJ staging gnosis handler at `http://localhost:7700` or via Unix socket.
- Policy: `config/gateway-policy-boj-example.yaml` from Phase A.
- Trust level source: `"header"` initially, switched to `"mtls"` after Phase B cert
  rotation runbook is exercised.

**E3 — Telemetry verification**

With staging traffic running:
- Confirm `[:http_capability_gateway, :access_decision]` events appear in the
  Prometheus scrape at `/metrics`.
- Confirm `GET /api/v1/minikaran` returns `status.status: "active"` after the
  learning phase.
- Confirm structured JSON logs appear in the log stream with `request_id` fields.
- Confirm `X-Trust-Level` header is set correctly on forwarded requests as seen
  by BoJ (read from BoJ access logs).

**E4 — Production rollout**

Roll out behind a feature flag or behind a percentage split (10% → 50% → 100%
of traffic directed through the gateway).

**E5 — Rollback runbook**

File: `docs/integration/gateway-rollback-runbook.md`

Covers:
- How to detect that the gateway is causing problems (elevated 502/503 rates,
  increased latency at p99).
- How to bypass the gateway (re-route traffic directly to BoJ gnosis handler)
  without downtime (requires traffic management — Cloudflare Tunnel rule, or
  container orchestration).
- How to disable the gateway permanently (remove the k9-svc deployment, update
  tier-2 config to `status: DISABLED`).

### Acceptance Criteria

- Gateway handles a declared traffic profile in staging for at least 24 hours
  without circuit breaker trips or elevated error rates.
- Telemetry verified (E3 complete).
- Rollback runbook exists and has been tested (manually walk through E5 once
  in staging before production rollout).
- Production rollout complete with no SLA regression (latency at p99 within
  D2 declared overhead + 20% safety margin).
- `[HTTP_CAPABILITY_GATEWAY]` section in BoJ Trustfile updated to
  `status: "DEPLOYED"` with `deployed_at` timestamp.

### Risks

- **Cowboy TLS in production:** First time running the gateway with mTLS in
  production. Cert expiry, CA rotation, and Cowboy TLS configuration errors
  are all possible. The rollback runbook must be tested before production.
- **Backend URL single-backend limitation:** The proxy module supports one
  `backend_url`. If BoJ is horizontally scaled, the gateway must be placed
  behind a load balancer or the proxy module must be extended (out of scope
  for this plan but noted for future work).
- **Policy size in production:** The Phase A example policy covers known routes.
  Undocumented routes (gnosis handler internals, health probes, metrics) must
  be added to the policy before go-live or they will be default-denied.

---

## Cross-Phase Notes

### Verb Governance Spec versioning

The policy file is a BoJ-repo artefact. It must be reviewed like any spec change
(PR required, approved by maintainer). When the OpenAPI spec changes, the policy
file must be updated in the same PR or the PR must document why the policy is
unchanged (e.g., the new route is not externally accessible).

### Trust header forwarding security invariant

The gateway strips `X-Trust-Level` from incoming requests unless the sender is in
`:trusted_proxies`. After Phase B (mTLS), the gateway sets `X-Trust-Level` from the
resolved mTLS trust level before forwarding to BoJ. BoJ's gnosis handler must treat
`X-Trust-Level` from `127.0.0.1` (or the gateway container IP) as authoritative and
from any other source as untrusted. This invariant must be documented in the Phase A
contract and tested in Phase C.

### Groove protocol

When Groove protocol is adopted estate-wide for inter-service communication, the
gateway ↔ BoJ forwarding path should be considered for Groove wrapping. This is
post-Phase E work.

### VeriSimDB audit trail

If `VeriSimDB` in the gateway is confirmed as a working integration (not a stub),
the audit trail (allow/deny decisions with path, verb, trust level, backend, rule name,
duration) will flow into the per-project VeriSimDB instance. This is valuable for
BoJ's audit posture. Confirm VeriSimDB integration status before Phase E.
