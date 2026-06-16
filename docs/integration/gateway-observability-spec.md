<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# HCG tier-2 — observability spec

**Version:** 0.1 (scaffold, Phase E)
**Date:** 2026-06-16
**Status:** Phase E scaffold. Names the gateway-emitted Prometheus metrics, gives PromQL templates for every signal listed in the rollout runbook §4.1/§4.2, and binds alert thresholds to the rollback triggers in runbook §5.1 and the perf contract's tolerance ratios. Absolute-µs values are deliberately left as `Phase D-4` references — once `bench/baseline.json` `_status` flips to `active` the queries here read against real numbers without further edits.
**ADR:** [`docs/decisions/0004-adopt-http-capability-gateway.md`](../decisions/0004-adopt-http-capability-gateway.md)
**Plan:** [`docs/integration/http-capability-gateway-plan.md`](http-capability-gateway-plan.md) (§ Phase E, E3 telemetry verification)
**Contract:** [`docs/integration/http-capability-gateway-boj-contract.md`](http-capability-gateway-boj-contract.md)
**Rollout runbook:** [`docs/integration/hcg-tier2-rollout-runbook.md`](hcg-tier2-rollout-runbook.md) (§ 4 signals, § 5 rollback)
**Load profile:** [`docs/integration/gateway-load-profile.md`](gateway-load-profile.md) (§ 2 SLO budgets)
**Perf contract (gateway side):** [`http-capability-gateway/docs/perf-contract.md`](https://github.com/hyperpolymath/http-capability-gateway/blob/main/docs/perf-contract.md)
**Tracking:** [`standards#91`](https://github.com/hyperpolymath/standards/issues/91) (parent), [`standards#100`](https://github.com/hyperpolymath/standards/issues/100) (Phase E)

> **File-format note.** Matches sibling integration docs (`http-capability-gateway-{plan,audit,boj-contract,policy-authoring}.md`, `gateway-load-profile.md`, `hcg-tier2-rollout-runbook.md`); the rollout runbook §4 anchors all signals here by exact path. The estate `.adoc` default is deliberately overridden for the `docs/integration/` set.

---

## 0. Scope

This document is the declarative half of Phase E §4 "Observability — what on-call watches". The runbook §4 names the signals at the human level ("p99 latency", "circuit-breaker state", "trust-level decision distribution"); this spec wires each signal to:

1. The **telemetry event** emitted by the gateway (audit document §5).
2. The **Prometheus metric** the `TelemetryMetricsPrometheus.Core` reporter exports for that event (gateway `lib/http_capability_gateway/application.ex` `telemetry_metrics/0`, lines 259–296).
3. A **PromQL query template** an on-call dashboard or alerting rule can paste verbatim.
4. An **alert threshold** anchored to a canonical source — the rollback runbook §5.1 trigger value, the perf contract tolerance ratio, or the load-profile SLO budget. Where the absolute number depends on Phase D-4 baseline collection, the spec names the formula and the lookup site instead of inventing a value.

In scope:

- Every signal listed in rollout runbook §4.1 (gateway-side) and §4.2 (BoJ-side).
- The mapping from rollback trigger (§5.1) to the alerting rule that fires it.
- The Minikaran anomaly endpoint as a secondary, complementary signal path.

Out of scope:

- Dashboard authoring (the !OWNER: rows in runbook §4.3 — the dashboard URL, the on-call rota). This spec gives the operator the queries; choosing the dashboard tool (Grafana / Cloudflare analytics / something else) is owner-driven per the runbook's existing scoping.
- Cloudflare-edge metrics (tier 1). Covered separately in `Trustfile.a2ml [CLOUDFLARE_EDGE_SECURITY]`.
- BoJ-internal cartridge or cartridge-tool metrics. The gateway sees BoJ as a single backend; cartridge-level observability is downstream.
- Long-term storage / retention policy. The spec defines what to scrape; how long to keep scrapes is an operator decision (the §4.3 dashboard URL row already covers that scope).

---

## 1. Gateway-side metrics inventory

Every gateway-emitted telemetry event has a corresponding Prometheus metric. The mapping below is normative; if a future PR adds a new event without a metric (or vice versa) the rollout runbook §1.5 smoke pre-check should fail before traffic shift.

The Prometheus metric names follow the `telemetry_metrics_prometheus_core` convention: dots become underscores, distribution metrics expose `_bucket`, `_count`, `_sum` series, counters expose a `_total` series. The names below are the metric prefixes the operator sees in `/metrics`.

| Telemetry event (audit §5) | Prometheus metric prefix | Type | Tags | Source |
|---|---|---|---|---|
| `[:http_capability_gateway, :request, :received]` | `http_capability_gateway_request_received_count` | gauge (last_value) | — | `application.ex:262` |
| `[:http_capability_gateway, :request, :completed]` | `http_capability_gateway_request_completed_count` | counter | — | `application.ex:263` |
| `[:http_capability_gateway, :request, :completed]` | `http_capability_gateway_request_completed_duration` | distribution | — | `application.ex:264-267` |
| `[:http_capability_gateway, :policy, :lookup]` | `http_capability_gateway_policy_lookup_duration` | distribution | — | `application.ex:270-273` |
| `[:http_capability_gateway, :access_decision]` | `http_capability_gateway_access_decision_count` | counter | `decision`, `verb`, `trust_level` | `application.ex:276-278` |
| `[:http_capability_gateway, :backend, :forward]` | `http_capability_gateway_backend_forward_count` | counter | — | `application.ex:281` |
| `[:http_capability_gateway, :backend, :response]` | `http_capability_gateway_backend_response_duration` | distribution | — | `application.ex:282-285` |
| `[:http_capability_gateway, :error]` | `http_capability_gateway_error_count` | counter | `error_type` | `application.ex:288` |
| `[:http_capability_gateway, :minikaran, :anomaly]` | `http_capability_gateway_minikaran_anomaly_count` | counter | `type` | `application.ex:293-295` |

### 1.1 Distribution buckets

Buckets are declared in microseconds and capture the gateway's own pipeline cost, not end-to-end RTT. The buckets are wide enough to accommodate the perf contract's six scenarios:

| Metric | Buckets (µs) | Source |
|---|---|---|
| `request_completed_duration` | `[100, 500, 1_000, 5_000, 10_000, 30_000]` | `application.ex:266` |
| `policy_lookup_duration` | `[10, 50, 100, 500, 1_000]` | `application.ex:272` |
| `backend_response_duration` | `[100, 500, 1_000, 5_000, 10_000, 30_000, 60_000]` | `application.ex:284` |

The `backend_response_duration` upper bucket is 60 ms because BoJ-attributable latency may include cartridge invocation; the gateway-attributable buckets stop at 30 ms because the load profile §2.2 budget puts p99 well under that.

### 1.2 Tags

Three counters are tagged. Tag cardinality is bounded:

- `decision` ∈ `{allow, deny, no_match, error}` — four-value set, no cardinality blow-up.
- `verb` ∈ `{GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS}` — seven-value allowlist enforced by `Gateway.safe_verb/1` (gateway `lib/http_capability_gateway/gateway.ex:65-77`); unknown methods short-circuit before reaching the access-decision event.
- `trust_level` ∈ `{untrusted, authenticated, internal}` — three-value set enforced by `SafeTrust.parse_trust/1`.
- `error_type` — open vocabulary but bounded by the gateway's enumerated error paths. Operator should monitor for cardinality growth here as a deployment-defect signal.
- `type` on `minikaran_anomaly_count` ∈ `{traffic_spike, trust_shift, latency_spike, path_novelty, error_spike}` — five-value set declared in the audit §1.6.

Total decision counter cardinality bound: `4 × 7 × 3 = 84` time series at saturation. Below the threshold where Prometheus storage becomes a concern.

---

## 2. Signal → query mapping (rollout runbook §4.1, gateway-side)

The runbook lists six gateway-side signals. Each subsection below names one, gives its PromQL query, and binds an alert threshold.

### 2.1 p50 / p95 / p99 latency per scenario

**Runbook signal:** "p50/p95/p99 latency per scenario (health / policy-deny fast-path / proxy allow)."

The harness scenarios (perf contract §Scenarios) are bench-only — production traffic doesn't carry a "scenario" tag — so the production equivalent is per-decision-class:

- `health endpoint` → `request_completed_duration` filtered by the `/health` route (path is not tagged on the metric; use the access log JOIN or filter via a relabel rule at scrape time).
- `policy deny (405 fast-path)` → `request_completed_duration` AND `access_decision_count{decision="deny"}` correlated in the dashboard, or — simpler — `access_decision_count{decision="deny"}` rate as a proxy.
- `exact route allow (proxy 200)` → `backend_response_duration` (this measures the dial-and-read against BoJ, which is the production equivalent of the loopback bench scenario).

PromQL templates:

```promql
# Gateway pipeline p99 (all paths, all decisions — the headline number)
histogram_quantile(0.99,
  sum by (le) (
    rate(http_capability_gateway_request_completed_duration_microseconds_bucket[5m])
  )
)

# Backend (BoJ) response p99 — what the gateway sees from BoJ on the allow path
histogram_quantile(0.99,
  sum by (le) (
    rate(http_capability_gateway_backend_response_duration_microseconds_bucket[5m])
  )
)

# Gateway-attributable overhead (allow path) ≈
#   request_completed_duration − backend_response_duration
# at matching percentiles. PromQL cannot subtract two histogram_quantile expressions
# directly; instead, plot both p99s on the same chart and read the gap.
```

**Alert threshold (rollback trigger §5.1):**

> "p99 latency at the rollout edge ≥ 2× Phase D baseline p99 for ≥ 5 minutes."

The `bench/baseline.json` p99 for the `exact route allow (proxy 200)` scenario is the anchor. Until D-4 lands real numbers, the alert rule is:

```promql
# Phase E rollback trigger: gateway p99 ≥ 2× baseline for ≥ 5 minutes.
# Replace ${BASELINE_REQUEST_P99_US} with the value from bench/baseline.json
# after D-4 lands real numbers and _status flips to active.
(
  histogram_quantile(0.99,
    sum by (le) (
      rate(http_capability_gateway_request_completed_duration_microseconds_bucket[5m])
    )
  )
  >
  bool ${BASELINE_REQUEST_P99_US} * 2
) == 1
```

Alert duration: 5 minutes (matching the runbook trigger).

### 2.2 Throughput (ips, per scenario)

**Runbook signal:** "Throughput (ips, per scenario)."

PromQL:

```promql
# Total requests/second
rate(http_capability_gateway_request_completed_count_total[1m])

# Allow path requests/second (the cost-class equivalent of the proxy-200 scenario)
sum(
  rate(http_capability_gateway_access_decision_count_total{decision="allow"}[1m])
)

# Deny path requests/second (the cost-class equivalent of the 405 fast-path scenario)
sum(
  rate(http_capability_gateway_access_decision_count_total{decision=~"deny|no_match"}[1m])
)
```

**Alert threshold (load profile §2.1):**

The §2.1 envelope is "sustained ≥ §1.1 median × 1.5; burst ≥ §1.1 peak × 1.2". §1.1 is `!OWNER:` (production measurement) so the absolute number is filled at operator time; the SLO breach rule is:

```promql
# Phase E throughput breach: sustained throughput exceeds the envelope budget.
# Replace ${SUSTAINED_BUDGET_RPS} with the gateway-load-profile §2.1 value
# computed as: !OWNER: (production median rps) × 1.5.
rate(http_capability_gateway_request_completed_count_total[5m])
  > ${SUSTAINED_BUDGET_RPS}
```

Pages as an SLO warning, not as an immediate rollback (the gateway can absorb modest overshoot — the load profile headroom is already 1.5×). Persistent breach (≥30 minutes) is a capacity-planning escalation, not a rollback trigger.

### 2.3 Circuit-breaker state

**Runbook signal:** "Circuit-breaker state (closed / half-open / open)."

The gateway emits no dedicated circuit-breaker telemetry event today (it only logs state transitions via `Logger.warning`). The proxy here is the **503 rate from the gateway**:

```promql
# 503s from the gateway proxy path (audit §1.4 K9-contract section + Gateway.enforce_with_contract/5
# returns 503 when the circuit breaker is open).
# A non-zero rate while access_decision_count{decision="allow"} is also non-zero
# means the gateway accepted the request but the backend was unreachable — exactly
# the circuit-open signal.
sum(
  rate(http_capability_gateway_request_completed_count_total[1m])
)
unless on() (
  sum(rate(http_capability_gateway_backend_forward_count_total[1m])) > 0
)
```

This is approximate — it captures "request completed without backend forwarding", which is the circuit-open behaviour. A precise signal would require a dedicated `[:http_capability_gateway, :circuit_breaker, :state_change]` event with `state` ∈ `{closed, half_open, open}` tags. **Follow-up:** open a tracking issue in the gateway repo (post-Phase-E, dashboard-quality improvement, not Phase E blocker).

**Alert threshold (rollback trigger §5.1):**

> "Circuit breaker trips ≥ 3 times in any 15-minute window."

A circuit-breaker trip surfaces as a sustained 503 spike from the `unless` query above. Until the dedicated event lands, monitor 503s and re-derive the trip count manually from the gateway log stream (`Logger.warning("Request rejected by circuit breaker", …)` — `gateway.ex:411`).

### 2.4 5xx rate (gateway-origin vs BoJ-passthrough)

**Runbook signal:** "5xx rate emitted by the gateway (gateway-origin 5xx vs BoJ-passthrough 5xx — keep these distinguishable)."

Gateway-origin 5xxs (the gateway returned a 5xx without forwarding to BoJ — circuit-breaker, policy-not-loaded, etc.):

```promql
# Gateway-origin 5xx ≈ requests that completed with no backend forward.
# (Audit §1.4: 503 from policy-not-loaded path, 503 from circuit breaker,
#  502 from proxy returns 500 — these all skip backend_forward_count
#  in the K9-contract failure paths.)
sum(rate(http_capability_gateway_request_completed_count_total[1m]))
  - sum(rate(http_capability_gateway_backend_forward_count_total[1m]))
```

BoJ-passthrough 5xxs (the gateway forwarded to BoJ, BoJ returned a 5xx):

```promql
# BoJ-passthrough 5xx: backend_forward_count was incremented but the resulting
# response was 5xx. The gateway does not currently tag response-status on the
# request_completed event, so this requires the BoJ access-log JOIN.
# Until that join exists, use the BoJ-side query in §3.3 below as the
# authoritative passthrough-5xx signal.
```

**Alert threshold (rollback trigger §5.1):**

> "Gateway-origin 5xx rate ≥ 1% of requests for ≥ 5 minutes."

```promql
# Phase E rollback trigger: gateway-origin 5xx ≥ 1% for ≥ 5 minutes.
(
  (
    sum(rate(http_capability_gateway_request_completed_count_total[5m]))
      - sum(rate(http_capability_gateway_backend_forward_count_total[5m]))
  )
  / sum(rate(http_capability_gateway_request_completed_count_total[5m]))
)
> 0.01
```

Alert duration: 5 minutes.

### 2.5 Policy reload counter

**Runbook signal:** "Policy reload counter (a spike during stable operation is a misconfiguration alarm)."

The gateway logs policy reloads via `PolicyCompiler.compile/2` (`Logger.info("Policy compiled successfully", …)`). No dedicated telemetry event exists yet — the proxy is the policy hot-reload SIGHUP audit trail at the OS level, or the gateway's log stream.

**Phase E posture:** **Treat this signal as a log-based alert, not a Prometheus signal, until a `[:http_capability_gateway, :policy, :reload]` event is added.** Open as a tracked follow-up in the gateway repo. The runbook §4.1 lists this signal explicitly so the operator knows to wire a log-based check; this spec confirms the absence of a metric path.

### 2.6 Trust-level decision distribution

**Runbook signal:** "Trust-level decision distribution (`untrusted` / `authenticated` / `internal`). Sudden shift indicates auth pipeline change."

PromQL:

```promql
# Per-trust-level allow rate as a fraction of total allow.
sum by (trust_level) (
  rate(http_capability_gateway_access_decision_count_total{decision="allow"}[5m])
)
/ on() group_left()
sum(
  rate(http_capability_gateway_access_decision_count_total{decision="allow"}[5m])
)
```

**Alert threshold:** No direct rollback trigger. The Minikaran anomaly detector (§4 below) already covers the "sudden shift" case via the `trust_shift` anomaly type — that's the existing dashboard signal. The PromQL above feeds a Grafana panel; the actionable alert is the Minikaran event.

---

## 3. Signal → query mapping (rollout runbook §4.2, BoJ-side)

§4.2 names three BoJ-side signals. The first two require BoJ-emitted Prometheus metrics that are not in this repo's scope; the third is a network-layer signal. This section names the queries each owner needs to wire on the BoJ side; the metric naming convention follows the project's existing telemetry (`BojRest.Router` decisions, `boj-server` Prometheus exporter — both !OWNER: scaffolded since BoJ-side telemetry is outside this Phase E channel).

### 3.1 Per-route trust-class distribution

**Runbook signal:** "Per-route trust-class distribution from `BojRest.Router` decisions."

PromQL template (assumes a BoJ-side `boj_router_decision_count_total{route, trust_class}` counter — !OWNER: scaffold against the actual `BojRest.Router` instrumentation):

```promql
# Per-route trust-class distribution. Replace boj_router_decision_count_total
# with whatever name the BoJ exporter uses.
sum by (route, trust_class) (
  rate(boj_router_decision_count_total[5m])
)
```

If BoJ does not currently expose this metric, the runbook §4.2 signal list is the unambiguous request: BoJ-side observability for the rollout requires emitting this counter before Phase E §3.1 (10% traffic) can begin. **Follow-up:** open as a BoJ-side prereq tracking item; reference this section.

### 3.2 `X-Trust-Level` from non-loopback peers — should be zero

**Runbook signal:** "`X-Trust-Level` arriving from non-loopback peers — should be zero. Any non-zero is a deployment defect (back-side bind exposed)."

The strongest enforcement is at the network layer (NetworkPolicy, firewall — landed via boj-server#173, runbook §1.4). This signal verifies the *invariant*; non-zero is a deployment defect that NetworkPolicy did not catch.

PromQL template (assumes a BoJ-side counter that distinguishes loopback from non-loopback origin):

```promql
# X-Trust-Level from non-loopback peers — must remain at zero.
# Replace metric name with the BoJ-side equivalent.
sum(
  rate(boj_router_trust_level_present_count_total{remote_origin!="loopback"}[5m])
)
> 0
```

**Alert threshold (rollback trigger §5.1):**

> "BoJ access logs show `X-Trust-Level` from non-loopback peers (a §3 invariant 4 violation in flight — the back-side bind is exposed)."

Any non-zero rate is the trigger. Immediate page; this is a §3 contract invariant violation.

### 3.3 BoJ 5xx rate (independent of gateway's view)

**Runbook signal:** "BoJ 5xx rate (independent of gateway's view)."

PromQL template:

```promql
# BoJ-emitted 5xx rate as a fraction of BoJ-handled requests.
# Replace metric names with the BoJ-side equivalents.
sum(rate(boj_http_responses_total{status=~"5.."}[5m]))
/ sum(rate(boj_http_responses_total[5m]))
```

**Alert threshold:** Pair with §2.4 above. A divergence between gateway-origin 5xx (§2.4) and BoJ 5xx (§3.3) localises the fault: gateway-origin > BoJ → fault is in the gateway pipeline (circuit-breaker, K9-contract, policy); BoJ 5xx > gateway-origin → fault is downstream of the gateway (cartridge crash, BoJ-internal). The runbook §5.1 5xx trigger is gateway-origin only — BoJ 5xx is a *diagnostic* signal, not a rollback trigger.

---

## 4. Minikaran anomaly endpoint — secondary signal path

The gateway emits `[:http_capability_gateway, :minikaran, :anomaly]` events tagged with `type` (audit §1.6), exported as `http_capability_gateway_minikaran_anomaly_count_total{type}`. The Minikaran handler also offers a JSON endpoint at `/api/v1/minikaran` (gateway `lib/http_capability_gateway/gateway.ex:228-232`) that returns the current anomalies, baseline summary, and operational status.

Five anomaly types (audit §5 dashboard subsection):

| Anomaly type | Meaning | Maps to runbook signal |
|---|---|---|
| `traffic_spike` | Path-level traffic above learned baseline. | §4.1 throughput. |
| `trust_shift` | Per-trust-level rate shifted from baseline distribution. | §4.1 trust-level decision distribution. |
| `latency_spike` | Per-percentile latency above learned baseline. | §4.1 p50/p95/p99 latency. |
| `path_novelty` | New path appeared (potential scan or new client). | §4.1 5xx rate (path-novel scans usually yield 4xx). |
| `error_spike` | Error-rate above learned baseline. | §4.1 5xx rate. |

PromQL:

```promql
# Anomaly rate by type (sum across all types should be near-zero in steady state).
sum by (type) (
  rate(http_capability_gateway_minikaran_anomaly_count_total[5m])
)
```

Minikaran is a **complementary** signal — it catches drift the percentile-and-rate queries above miss (sudden-but-modest distribution shift, novel path appearing under the gateway). Phase E posture: gate the §3.1 sign-off on Minikaran reporting baseline established (`GET /api/v1/minikaran` returns `status.status == "active"`); use the anomaly counter as a *paged* signal only when the on-call has time to triage (it is noisier by design than the strict-percentile alerts).

---

## 5. Alert rules summary

The rollback runbook §5.1 lists six triggers. The table below maps each trigger to the PromQL alert rule in this spec.

| Runbook §5.1 trigger | Spec section | PromQL anchor | Severity |
|---|---|---|---|
| p99 latency at the rollout edge ≥ 2× Phase D baseline p99 for ≥ 5 minutes | §2.1 | `request_completed_duration_microseconds_bucket` × 2 | page on-call |
| Gateway-origin 5xx rate ≥ 1% for ≥ 5 minutes | §2.4 | `(request_completed − backend_forward) / request_completed` > 0.01 | page on-call |
| Circuit breaker trips ≥ 3 times in any 15-minute window | §2.3 | derived from 503 spike + log inspection until dedicated event lands | page on-call |
| BoJ access logs show `X-Trust-Level` from non-loopback peers | §3.2 | `boj_router_trust_level_present_count{remote_origin!="loopback"}` > 0 | page on-call (any non-zero) |
| VeriSimDB / audit-trail write failures ≥ 1% | §4 + audit §4 | not yet exposed as a Prometheus metric (VeriSimDB integration is `audit_allow/audit_deny` cast-only) | follow-up: emit `[:http_capability_gateway, :verisimdb, :write_failure]` event |
| On-call judgement | — | — | always — overrides the rules above |

The last-row "follow-up" row is a gap this spec surfaces. Phase E §1.3 already lists VeriSimDB integration status as an `!OWNER:` confirmation; if VeriSimDB is confirmed as a real integration (not a stub), the write-failure metric becomes a deferred deliverable on the gateway side (open a tracking issue post-Phase-E).

---

## 6. Phase E acceptance — how this spec gates §3 traffic shift

The rollout runbook §3.1 ("10% traffic") success criteria are:

> - p99 latency at production endpoints within Phase D baseline × 1.5 (the perf-regression p99 tolerance).
> - 5xx rate not elevated vs the BoJ-direct baseline (same 24-hour window the previous day).
> - No circuit-breaker trips on the gateway.
> - No `X-Trust-Level` mismatches in BoJ access logs (gateway should be the only source).

This spec gives the operator one PromQL query per success criterion (§2.1, §2.4, §2.3, §3.2). The §3.1 sign-off is a green-on-all-four check; the dashboard built from these queries is the human-readable surface of that check.

Phase E §3.4 (decommission BoJ direct external access) further requires all queries above run green for the §3.3 7-day soak window. The PromQL templates here remain unchanged across that window — the soak is a duration, not a different signal set.

---

## 7. References

- Rollout runbook — `docs/integration/hcg-tier2-rollout-runbook.md` (§4 signal list, §5 rollback triggers, §6 Trustfile flip).
- Load profile — `docs/integration/gateway-load-profile.md` (§2 SLO budgets, §3.4 bench harness reference).
- Audit — `docs/integration/http-capability-gateway-audit.md` (§1.6 telemetry, §5 telemetry shape, §1.4 mTLS path notes).
- Plan — `docs/integration/http-capability-gateway-plan.md` (§Phase E E3 telemetry verification).
- Perf contract (gateway side) — `http-capability-gateway/docs/perf-contract.md` (tolerance ratios that anchor §2.1).
- Gateway metric definitions — `http-capability-gateway/lib/http_capability_gateway/application.ex` `telemetry_metrics/0` (lines 259–296).
- Gateway request flow — `http-capability-gateway/lib/http_capability_gateway/gateway.ex` (§2.3 circuit-breaker behaviour, §2.6 trust-level extraction).
