<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# http-capability-gateway — Tier-2 Load Profile

**Version:** 1.0 (draft, Phase D)
**Date:** 2026-05-31
**Status:** Phase D deliverable D1 — load profile declaration. Operator-fillable markers (`!OWNER:`) cover the production-traffic measurements the BoJ owner must populate before Phase E §1.1 can be checked off.
**ADR:** [`docs/decisions/0004-adopt-http-capability-gateway.md`](../decisions/0004-adopt-http-capability-gateway.md)
**Plan:** [`docs/integration/http-capability-gateway-plan.md`](http-capability-gateway-plan.md) (§ Phase D, D1)
**Contract:** [`docs/integration/http-capability-gateway-boj-contract.md`](http-capability-gateway-boj-contract.md)
**Perf contract (gateway side):** [`http-capability-gateway/docs/perf-contract.md`](https://github.com/hyperpolymath/http-capability-gateway/blob/main/docs/perf-contract.md)
**Companion benchmark results doc (D2):** `docs/integration/gateway-benchmarks.md` (lands once `bench/baseline.json` `_status` flips to `active`)
**Rollout runbook:** [`docs/integration/hcg-tier2-rollout-runbook.md`](hcg-tier2-rollout-runbook.md)
**Tracking:** [`standards#91`](https://github.com/hyperpolymath/standards/issues/91) (parent), [`standards#99`](https://github.com/hyperpolymath/standards/issues/99) (Phase D)

> **File-format note.** Matches sibling integration docs (`http-capability-gateway-{plan,audit,boj-contract,policy-authoring}.md`, `hcg-tier2-rollout-runbook.md`); the plan §D1 normatively prescribes `docs/integration/gateway-load-profile.md`. The estate `.adoc` default is deliberately overridden for the `docs/integration/` set so the integration plan can name documents by exact path.

---

## 0. Scope

This document declares the **load envelope** the HCG tier-2 gateway must absorb when sitting between Cloudflare edge (tier 1) and BoJ's unified Zig API gnosis handler (tier 3). It is the contract the Phase D benchmark harness measures against and the Phase E rollout uses to size soak windows and tolerance margins.

In scope:

1. **Production traffic baseline** — the requests/second the BoJ gnosis handler receives in production today (§1). The gateway must, post-rollout, handle the same arrival rate.
2. **Gateway load profile target** — the rate the gateway must serve at, expressed as `production-rate × headroom`, plus the per-request overhead budget within which the gateway pipeline must stay (§2).
3. **Measurement environment** — the hardware, runtime, and policy size the published Phase D benchmark numbers are collected against (§3).

Out of scope:

- Per-scenario latency numbers themselves. Those live in `bench/baseline.json` (the harness output, gateway repo) once the D-4 rebaseline ritual has collected them, and are summarised for BoJ readers in the D2 deliverable `docs/integration/gateway-benchmarks.md`.
- BoJ-internal latency (the gnosis handler's own processing time). The gateway treats BoJ as a single backend with opaque cost; the gateway-side perf contract isolates gateway-attributable cost only.
- Cloudflare-edge load shaping (tier 1) and BEAM-supervisor back-pressure (tier 3). Both are covered separately in `Trustfile.a2ml [CLOUDFLARE_EDGE_SECURITY]`.

---

## 1. Production traffic baseline

The gateway will, in Phase E, sit in front of BoJ's gnosis handler with no peer or shard splitting (single-backend proxy, per ADR-0004 § Risks). It must therefore absorb the *full* production arrival rate BoJ sees today. The figures below describe that rate.

> **Operator action required before Phase E §1.1 close.** All `!OWNER:` rows are measurements that must come from production telemetry — not estimates. Until they are filled in, the load profile is **declarative-only** and the Phase E rollout cannot move past §1.1.

### 1.1 Arrival rate (the BoJ-direct steady state)

| Measure | Value | Source |
|---|---|---|
| Median sustained requests/second (24h rolling) | `!OWNER:` | BoJ access logs / Prometheus `http_requests_total` rate over 24h. |
| p95 sustained requests/second (1-minute buckets, 24h window) | `!OWNER:` | Same. |
| Peak burst (1-second bucket, 7-day window) | `!OWNER:` | Same. |
| Diurnal pattern (peak hour / trough hour, UTC) | `!OWNER:` | Same. |
| Verb mix (% GET / POST / other) | `!OWNER:` | Same; cross-check against `[CLOUDFLARE_EDGE_SECURITY]` rate-limit dashboards. |

The arrival-rate baseline is measured **on the externally visible port** today (BoJ-direct, no gateway interposed). Post-rollout the same rate hits the gateway first; the gateway must not silently shed any of it (a fast 429/403 IS a valid response, but the *arrival* must be absorbed without the gateway becoming the bottleneck).

### 1.2 Path mix

The gateway's per-request cost is path-sensitive: short-circuit denies cost less than allow-and-proxy paths (perf contract § Scenarios, gateway repo). The path mix below sizes the *weighted* per-request cost the gateway will pay.

| Path class | Example route(s) | % of production traffic | Gateway cost class |
|---|---|---|---|
| Health probe (cheap allow) | `/health`, `/.well-known/boj-node-pubkey` | `!OWNER:` | `health endpoint` (perf-contract.md scenario 1) |
| Verb-denied (cheap deny) | DELETE/PUT/PATCH to any wired route | `!OWNER:` (typically near-0 from legitimate traffic; non-zero from scanners) | `policy deny (405 fast-path)` (scenario 2) |
| Cartridge invoke (allow + proxy) | `POST /cartridge/:name/invoke`, `POST /cartridge/:name/sse` | `!OWNER:` | `exact route allow (proxy 200)` (scenario 3) |
| Cartridge list/detail (allow + proxy) | `GET /cartridges`, `GET /cartridge/:name` | `!OWNER:` | `exact route allow (proxy 200)` (scenario 3) |
| Other declared-and-wired routes | per `config/gateway-policy-boj-example.yaml` | `!OWNER:` | `exact route allow (proxy 200)` (scenario 3) |

The seven cost-class buckets above match the six Benchee scenarios in the gateway repo's `bench/gateway_latency.exs` (plus the `health endpoint` scenario, which doubles as both health probe and pipeline-floor) so the per-class weighting is a direct lookup against the published per-scenario percentiles in `bench/baseline.json`.

### 1.3 Connection profile

mTLS is the Phase B primary trust path. Per-connection handshake cost is amortised over the requests served on that connection; the relevant operator metric is therefore *requests per kept-alive connection*, not raw connections/second.

| Measure | Value | Source |
|---|---|---|
| Median requests per kept-alive connection | `!OWNER:` | Cloudflare access logs (connection ID grouping) or BoJ-direct access logs if pre-rollout. |
| p95 requests per kept-alive connection | `!OWNER:` | Same. |
| New-connection rate (handshakes/second, p95 over 1-minute buckets) | `!OWNER:` | Same. |

The bench harness covers both ends of this spectrum:

- **Cold:** `mTLS handshake (test CA)` (scenario 5) — every iteration pays one handshake. Upper bound when N=1.
- **Warm:** `mTLS amortised (test CA, N=16 requests over kept-alive)` (scenario 6) — handshake amortised over 16 requests. Lower bound for steady-state.

The operator's measured `requests-per-connection` value sits somewhere on the interpolation between these two; §2.4 tracks the consequence for the per-request budget.

---

## 2. Gateway load profile target

Given §1, the gateway must serve at least the rates declared here without breaching the per-request overhead budget.

### 2.1 Throughput envelope

| Target | Value | Rationale |
|---|---|---|
| Sustained throughput | ≥ §1.1 median × **1.5** (headroom) | The gateway absorbs production arrival rate plus 50% headroom for diurnal variation and scanner traffic. |
| Burst throughput (1-second window) | ≥ §1.1 peak burst × **1.2** | Match observed peak with modest cushion; relies on Cowboy's accept-pool sizing covered in §3.3. |
| 429/403 short-circuit throughput | unbounded (limited by acceptor pool) | Verb-denied and policy-denied requests must not queue behind allow-path latency; the `policy deny (405 fast-path)` scenario measures this in isolation. |

The headroom multipliers are deliberately fixed (1.5 / 1.2) rather than derived per-deploy: a tighter envelope would make the rollout brittle to mid-rollout traffic growth; a looser one would over-provision the bench harness against a real signal it never sees. If the §1.1 measurements arrive *higher* than the existing capacity assumptions in the rollout runbook, that is a Phase E §1.1 escalation, not a number to silently round down.

### 2.2 Per-request overhead budget

The gateway adds a hop in the request path; the ADR-0004 Negative-consequence § Latency overhead names a target of `< 2ms median, < 5ms p99 for a policy with 100 rules`. The BoJ example policy has **28 rules** (`config/gateway-policy-boj-example.yaml`, recounted 2026-05-31 — 28 routes across all exposure tiers). With a smaller policy than the ADR's 100-rule reference, the budget below is set tighter on the median path and matches the ADR on tail:

| Percentile | Budget (per-request gateway overhead) | Bench scenario it applies to |
|---|---|---|
| p50 | < 1.5 ms | `exact route allow (proxy 200)` minus `health endpoint` (the proxy-attributable cost) |
| p95 | < 3 ms | Same. |
| p99 | < 5 ms | Same. |

"Gateway overhead" is defined as the **gateway-attributable** cost: per perf contract § Scope, the harness already strips real-network RTT and real-backend processing time via the in-process loopback backend, so `exact route allow (proxy 200) − health endpoint` isolates the proxy hot path's gateway-attributable cost. The Phase D-4 rebaseline ritual populates the numerator; this section is the denominator.

Tolerance ratios (perf-regression CI gate) are set in `bench/baseline.json::tolerance`. They are looser than this budget because tolerance-ratio is *regression detection* (catch a 30% p95 worsening), whereas the budget here is *absolute SLO* (do not breach 3 ms regardless of historical trend).

### 2.3 Stealth and deny budget

Routes with `exposure: "internal"` and `stealth: { enabled: true, status_code: 404 }` MUST cost no more than a public route returning the same status:

| Class | Budget |
|---|---|
| Stealth-404 (internal-only path, untrusted caller) | p99 ≤ `policy deny (405 fast-path)` × **1.1** |

The 10% latitude allows for the extra `if exposure==:internal` branch in the policy evaluator without making the budget brittle to a fast-path refactor that re-orders the branches.

### 2.4 mTLS handshake budget

From §1.3 the gateway will see a mix of fresh handshakes and amortised kept-alive requests. The bench scenarios bracket the per-request cost:

- Cold: `mTLS handshake (test CA)` per-iteration cost.
- Warm: `mTLS amortised (test CA, N=16)` per-iteration cost = `(handshake + 16 × request) / 16`.

The **weighted per-request mTLS cost** is:

```
weighted = (1 / R) × cold  +  (1 − 1 / R) × warm_per_request
```

where `R` is §1.3's measured median requests-per-kept-alive-connection. Operator-fillable for both numerator and denominator at Phase E §1.1 sign-off; this section names the formula so the calculation is reviewable, not improvised.

---

## 3. Measurement environment

The published Phase D benchmark numbers (and the perf-regression CI gate that watches them) come from a single, named environment. Reproducibility is the point: any reviewer must be able to re-run the harness on the same target and get numbers in the same order of magnitude.

### 3.1 Hardware reference

| Element | Value | Source |
|---|---|---|
| Runner | GitHub Actions `ubuntu-latest` | `.github/workflows/perf-regression.yml` and `.github/workflows/perf-rebaseline.yml` in the gateway repo, pinned to the same target so collected numbers are gate-comparable. |
| Architecture | `x86_64` | GHA `ubuntu-latest` default. |
| Memory | Per GHA `ubuntu-latest` SKU (currently 16 GB; subject to GHA pool changes — variability is the cost of using a shared runner). | GHA-documented. |

The perf contract (gateway repo) names this choice deliberately: "the CI environment IS the published reference, deliberately chosen because it is the environment every reviewer can reproduce without local hardware variance." If a dedicated runner is later adopted (perf-contract.md § Targets calls this out as a Phase-D-4-revisit decision), that switch will land as a versioned rev of this document, not a silent baseline replacement.

### 3.2 Runtime

| Element | Value | Source |
|---|---|---|
| Elixir | `1.19` | `http-capability-gateway/.tool-versions` (`elixir 1.19.5-otp-28`); `mix.exs` requires `~> 1.19`. |
| OTP | `28` | Same. |
| Erlang VM flags | OTP-default (`+sbwt none +sbwtdcpu none +sbwtdio none` NOT applied — staying on defaults keeps the bench reproducible without per-runner tuning). | Confirmed via inspection of `bench/gateway_latency.exs` startup; no `:erlang.system_flag/2` calls before the harness runs. |
| Cowboy | `~> 2.7` (per ADR-0004 § Phase B reference) | `http-capability-gateway/mix.lock`. |

BoJ-side runtime (`elixir 1.18.4-otp-25`) is **not** the gateway runtime: the gateway is a separate BEAM application (ADR-0004 § Negative consequences). The runtime above is the gateway's, not BoJ's. Mismatched OTP majors across the seam are fine — the seam is HTTP, not BEAM-native message passing.

### 3.3 Policy size

| Element | Value | Source |
|---|---|---|
| Routes in published example policy | **28** | `config/gateway-policy-boj-example.yaml`, counted 2026-05-31 (`grep -cE '^    - path:'`). |
| DSL version | `"1"` | Same. |
| Global verbs declared | per `governance.global_verbs` (typically `[GET, POST]`; DELETE/PUT/PATCH/OPTIONS deliberately absent — the core verb-governance win) | Same. |
| Lookup classes used | exact + regex (cartridge-detail, cartridge-invoke, cartridge-sse, grpc-method) | Same. |

The ADR's reference budget (`100 rules`) is an estate ceiling, not the current size. Phase D-4 baseline numbers are collected against the *current* 28-rule policy, which is the policy Phase E will go live with. If/when the policy grows past 50 rules a rebaseline-and-revise of §2.2 is required (the regex-lookup class scales differently from exact-lookup, per `bench/gateway_latency.exs` scenario commentary).

### 3.4 Bench harness reference

| Component | Path (gateway repo) | Role |
|---|---|---|
| Benchee driver | `bench/gateway_latency.exs` | Runs the six published scenarios. |
| Baseline file | `bench/baseline.json` | Holds p50 / p95 / p99 / ips per scenario; `_status` field gates the perf-regression CI gate. |
| Rebaseline driver | `bench/rebaseline.exs` | Regenerates `bench/baseline.json` from `bench/results.json`. |
| Rebaseline workflow | `.github/workflows/perf-rebaseline.yml` | `workflow_dispatch`-only automation that runs the driver on `ubuntu-latest` and opens a `perf: rebaseline (standards#99)` PR. |
| Regression gate | `.github/workflows/perf-regression.yml` | Per-PR gate; non-blocking while `_status == "scaffold-placeholder"`. |
| Per-scenario contract | `docs/perf-contract.md` (gateway repo) | Names each scenario, units, tolerance ratios, baseline lifecycle. |

---

## 4. How this profile feeds Phase D and Phase E

### 4.1 Phase D close (standards#99)

The Phase D acceptance criteria (plan § Phase D) are:

1. Load profile document exists. → **This document.** ✓ once landed.
2. Median / p95 / p99 latency numbers published in `docs/integration/gateway-benchmarks.md`. → D2 deliverable; lands once D-4 rebaseline ritual (gateway repo) flips `bench/baseline.json` `_status` from `scaffold-placeholder` to `active` and the resulting numbers are reflected back here as `gateway-benchmarks.md`.
3. Gateway overhead number published (vs. direct BoJ, no gateway). → D2 deliverable; the formula is §2.2 (`exact route allow (proxy 200) − health endpoint`).
4. CI regression step configured. → Already in place per `http-capability-gateway/.github/workflows/perf-regression.yml` (PR #12 scaffold + PR #22 scenario expansion + PR #26 rebaseline-bootstrap).
5. Benchmark results do NOT fabricate numbers. → Enforced by the rebaseline workflow's `workflow_dispatch` collection on `ubuntu-latest`.

### 4.2 Phase E gate (standards#100, runbook §1.1)

The rollout runbook §1.1 "Phase D deliverables landed" checklist gates the Phase E traffic shift on:

- D-2 (loopback backend fixture) merged — **gateway PR #14, merged.**
- D-3 (real CI regression alert armed; `bench/baseline.json _status` flipped to `"active"`) — **partial: scenarios + gate scaffold landed via gateway PR #12 / #22; `_status` flip pending D-4 numbers.**
- D-4 (real baseline numbers populated; p50/p95/p99/ips for all six scenarios) — **pending: gateway PR #26 added the `workflow_dispatch` automation; the rebaseline PR itself has not yet been opened.**

Once D-4 lands and `_status` is flipped, the absolute budget in §2.2 of this document is the SLO the rollout watches at every soak window (§3.1 / §3.2 of the runbook), and the perf-regression CI gate becomes the *regression-detection* arm. Two independent guards — one against absolute breach, one against silent drift — both grounded in this profile.

---

## 5. References

- ADR-0004 — `docs/decisions/0004-adopt-http-capability-gateway.md` (§ Phase D row of the integration table; § Negative consequences § Latency overhead for the ADR-level budget).
- Integration plan — `docs/integration/http-capability-gateway-plan.md` (§ Phase D for the deliverable list; § Cross-Phase Notes for surface-drift discipline).
- Contract — `docs/integration/http-capability-gateway-boj-contract.md` (the seam this profile sizes traffic through).
- Rollout runbook — `docs/integration/hcg-tier2-rollout-runbook.md` (§1.1 prereqs that gate on this document).
- Perf contract (gateway side) — `http-capability-gateway/docs/perf-contract.md` (the six scenarios, the tolerance ratios, the baseline lifecycle).
- Bench harness — `http-capability-gateway/bench/gateway_latency.exs`, `bench/baseline.json`, `bench/rebaseline.exs`.
- Policy under test — `config/gateway-policy-boj-example.yaml` (28-route example, the size against which Phase D-4 baseline is collected).
