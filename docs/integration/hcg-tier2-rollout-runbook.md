<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# HCG tier-2 — rollout & rollback runbook

**Version:** 0.8 (BoJ-side observability spec prereq, Phase E in-progress)
**Date:** 2026-06-22 (rev. from 2026-06-15)
**Status:** Phase E deliverables E1 (deploy spec) + E5 (rollback runbook) drafted; live gateway policy (`config/gateway-policy-boj.yaml`) promoted from the worked example (§1.5); `scripts/hcg-policy-smoke.sh` lands as the checked-in §1.5 operator pre-check (deny-path covers gateway-alone; `--with-backend` adds allow-path coverage); §1.5 verb-canary block covers OPTIONS, regex-route DELETE, and wrong-verb-on-listed-path; a path-canary exercises the no-match default-deny branch (synthetic unknown path with a `global_verbs` verb); a stealth-profile canary pins the deny *status code* — internal+stealth routes must return 404 (capability existence hidden) and authenticated routes must return 403, so a missing-`:stealth_profiles` misconfiguration is caught instead of slipping past the generic any-4xx deny pattern; and `docs/integration/boj-side-observability-spec.md` now declares the BoJ-side telemetry events + Prometheus metric names that back the §4.2 signals — wired into §1.4 as a stop-the-rollout prerequisite, with the actual `BojRest.Router` emission left as a follow-up PR per the spec's §7 checklist. Owner-input markers (`!OWNER:`) remain to be filled before any traffic-shift action is taken.
**ADR:** [`docs/decisions/0004-adopt-http-capability-gateway.md`](../decisions/0004-adopt-http-capability-gateway.md)
**Plan:** [`docs/integration/http-capability-gateway-plan.md`](http-capability-gateway-plan.md) (§ Phase E)
**Contract:** [`docs/integration/http-capability-gateway-boj-contract.md`](http-capability-gateway-boj-contract.md)
**Tracking:** [`standards#91`](https://github.com/hyperpolymath/standards/issues/91) (parent), [`standards#100`](https://github.com/hyperpolymath/standards/issues/100) (Phase E)

> **File-format note.** Matches sibling integration docs (`http-capability-gateway-{plan,audit,boj-contract,policy-authoring}.md`); the integration plan §E5 normatively prescribes `.md` for the rollback runbook (the wider rollout-and-rollback scope folds in here per acceptance criterion 3 of `standards#100`). The estate `.adoc` default is deliberately overridden for the `docs/integration/` set.

> **Phase-D status (2026-06-08).** Phase D (`standards#99`) is **closed** — joint-closed via boj-server#168 (D-1 load profile, 2026-06-01) on top of the gateway-side D-1..D-3 scaffold + D-4 bootstrap (http-capability-gateway#12 / #14 / #22 / #26 / #30, all merged by 2026-06-02). The perf-regression gate is wired and the harness covers five scenarios. Two owner-driven Phase-D follow-ups remain before §1.1 below can sign off all four boxes: dispatching the `perf-rebaseline.yml` workflow to populate real `bench/baseline.json` numbers, and flipping `_status` from `scaffold-placeholder` to `active` to arm the gate. Both are workflow dispatches plus a maintainer-merge of the generated `perf: rebaseline (standards#99)` PR; no further code changes are required.

---

## 0. Scope

This runbook covers:

1. **Prerequisite checklist** — what must be green before the first staging-to-production traffic shift can be initiated (§1).
2. **Staging cut-over** — bringing the HCG tier-2 stack up in front of BoJ staging, validating telemetry and the seam (§2).
3. **Production rollout** — staged traffic-shift from BoJ-direct to HCG-fronted, percentage-by-percentage (§3).
4. **Observability** — dashboards and signals on-call must be watching (§4).
5. **Rollback** — detection, immediate-bypass, and permanent-disable procedures (§5).
6. **Post-rollout verification + Trustfile flip** — the final acceptance steps that close `standards#100` (§6).

What is **out of scope**:

- HCG internals (policy DSL, ETS table layout, proxy code paths) — covered in `http-capability-gateway/docs/`.
- Cloudflare-edge configuration (tier 1) — covered in `Trustfile.a2ml [CLOUDFLARE_EDGE_SECURITY]`.
- BEAM supervisor / cartridge rate-limiting (tier 3/4) — covered separately in `Trustfile.a2ml`.
- Horizontal scaling of BoJ behind the gateway (single-backend limitation, noted as post-Phase-E in the plan).

---

## 1. Prerequisites checklist

These must **all** be green before any traffic-shift action is taken. A red item is a stop-the-rollout condition; do not paper over it.

### 1.1 Phase D deliverables landed

- [x] Phase D-1 (Benchee harness + comparator + non-blocking CI gate) — http-capability-gateway#12 (2026-05-20).
- [x] Phase D-2 (loopback backend fixture so the allow scenario measures real dial-and-read cost) — http-capability-gateway#14 (2026-05-26).
- [x] Phase D-3 (dedicated trust-header-rewrite + mTLS handshake scenarios; schema-drift hardening) — http-capability-gateway#22 (2026-05-27), #30 (2026-06-02).
- [x] Phase D-4 bootstrap (`workflow_dispatch` rebaseline automation on `ubuntu-latest`) — http-capability-gateway#26 (2026-05-30).
- [x] Phase D-1 load-profile declaration (this repo's denominator) — boj-server#168 (2026-06-01); joint-closed `standards#99`.
- [ ] **Pending owner action — D-4 rebaseline + arm.** Dispatch `Perf Rebaseline` workflow on `hyperpolymath/http-capability-gateway` Actions tab, review the generated `perf: rebaseline (standards#99)` PR (real p50/p95/p99/ips for all five scenarios), and either flip `bench/baseline.json _status` from `scaffold-placeholder` to `active` in the same PR or in an immediate follow-up. Until this lands the regression gate runs in non-blocking scaffold mode — Phase E acceptance criterion 2 ("load that matches Phase D benchmark numbers") cannot be evaluated against absolute numbers.
- [ ] CI on `hyperpolymath/http-capability-gateway:main` is green for the most recent commit including the `Perf Regression` workflow.

> The Phase E acceptance criterion 2 references "load that matches Phase D benchmark numbers". The scaffold-mode gate catches the *shape* of a regression (per-scenario tolerance ratios) but not absolute breach of the load-profile budget published in `docs/integration/gateway-load-profile.md` § 2; the rebaseline + active flip is what arms the absolute check.

### 1.2 Phase A/B/C contract artefacts in place

- [x] Phase A contract: [`http-capability-gateway-boj-contract.md`](http-capability-gateway-boj-contract.md) (v1.0, 2026-05-18).
- [x] Phase A example policy: `config/gateway-policy-boj-example.yaml` (referenced by plan §E2).
- [x] Phase B mTLS-as-primary trust path: HCG `lib/http_capability_gateway/proxy.ex` `build_backend_headers/1` + Cowboy TLS config (http-capability-gateway#10).
- [x] Phase C trust-header strip + seam tests: HCG strip (http-capability-gateway#11); BoJ-side §3 invariant 3 enforcement in `elixir/lib/boj_rest/trust_policy.ex` line 73 (`def satisfies?(_required, _trust, false), do: false`), merged in boj-server#106 (commit `40e46f6f`).
- [x] Phase C `[SEAMS]` declaration: `.machine_readable/contractiles/trust/Trustfile.a2ml [SEAMS]` (boj-server#90).

### 1.3 Operational prerequisites — `!OWNER:` block

These cannot be inferred from the code/contract; the owner must fill them before §3 begins.

- [ ] `!OWNER:` On-call rotation defined for the gateway during rollout (primary + secondary). Contact: __________.
- [ ] `!OWNER:` Cloudflare zone(s) targeted for the rollout listed with current routing. _(Plan §E2 anticipates Cloudflare Tunnel rule or container orchestration as the traffic-shift mechanism — choose one.)_
- [ ] `!OWNER:` Traffic-shift mechanism chosen — Cloudflare Tunnel rule **OR** container orchestration **OR** Cloudflare percentage split — and pre-staged.
- [ ] `!OWNER:` Production mTLS certificate material provisioned (CA cert path, client CA, server cert+key). Path on prod host: __________.
- [ ] `!OWNER:` Observability dashboard URLs filled into §4 below.
- [ ] `!OWNER:` Stakeholder notification window agreed (rollout cannot start during a freeze; check `Mustfile`/governance for any active freeze).
- [ ] `!OWNER:` Cert-rotation runbook for the gateway TLS CA exists or is filed as follow-up (plan §E1 calls this out separately).
- [ ] `!OWNER:` VeriSimDB integration status confirmed (real vs stub — plan §E "VeriSimDB audit trail"). Affects audit-trail acceptance.

### 1.4 BoJ-side prerequisites

- [x] BoJ codebase defaults its container/Elixir back-side bind to loopback so the externally-facing port is not opened by the in-repo defaults: Elixir Cowboy bind tightening (boj-server#130), k8s Service ClusterIP (boj-server#131), Zig-adapter `APP_HOST=127.0.0.1` across `stapeln.toml`, `entrypoint.sh`, `compose.prod.yaml` (boj-server#132, merged 2026-05-20). Deployment-time confirmation that the staging port really is closed at the network layer (firewall / NetworkPolicy / container network) remains an operator pre-check before §2.1.
- [x] BoJ `BojRest.TrustPolicy.satisfies?/3` non-loopback-deny clause present — verified at `elixir/lib/boj_rest/trust_policy.ex:73` (`def satisfies?(_required, _trust, false), do: false`). Phase C invariant 3 enforcement; landed in boj-server#106.
- [x] Phase E NetworkPolicy hardening (back-side reachability restricted) — boj-server#173.
- [x] HCG-policy SSE-route coverage (`POST /cartridge/:name/sse` governed alongside `cartridge-invoke-post`) — boj-server#165.
- [ ] **BoJ-side observability emitted.** Four telemetry events declared in [`boj-side-observability-spec.md`](boj-side-observability-spec.md) §1 are emitted by `BojRest.Router`; the five Prometheus metrics in that spec §2 appear in a `/metrics` scrape; the `metrics-get` policy rule in that spec §5 governs the endpoint; and the `scripts/hcg-policy-smoke.sh` stealth canary covers it. Until this lands, §3.1 success criterion 4 ("No `X-Trust-Level` mismatches in BoJ access logs") and rollback trigger §5.1 row 4 are unobservable via Prometheus — the only signal path is BoJ structured logs, which the §4 dashboards do not currently consume. Spec landed; the wiring PR follows the spec's §7 checklist.
- [ ] `Trustfile.a2ml [CLOUDFLARE_EDGE_SECURITY].rate_limiting.tier_2_gateway.status` currently `"PENDING — http-capability-gateway wiring forthcoming"` (line 900). _The flip to a real status is the **last** action; see §6._

### 1.5 Gateway-side prerequisites

- [ ] Gateway Containerfile built and signed as a `.ctp` bundle via cerro-torre (plan §E1). `pedigree.security.signature` + `pedigree.validation.checksum` in `container/gateway-deploy.k9.ncl` are `PLACEHOLDER` until this step runs; cerro-torre signing is a separate operator action gated on key-handling discipline.
- [x] `container/gateway-deploy.k9.ncl` exists in the gateway repo (plan §E1) — http-capability-gateway#38 (2026-06-03). Five-level k9-svc pedigree (Snout / Scent / Leash / Gut / Muscle) modelled on `boj-server:container/deploy.k9.ncl`; per-environment `BACKEND_URL` (`http://127.0.0.1:7700` staging, `http://unix:/run/boj/gnosis.sock:/` production); trust source `"header"` staging → `"mtls"` production after §2.4 rehearsal; `max_unavailable = 0`; `failure_mode = "fail-closed"` matching the `[SEAMS] gateway-boj-gnosis` declaration.
- [x] Gateway policy file in place: `config/gateway-policy-boj-example.yaml`, covering all BoJ surface routes (`/.well-known/boj-node-pubkey`, `/health`, `/menu`, `/cartridges`, `/cartridge/:name`, `/cartridge/:name/invoke`, `/cartridge/:name/sse`, plus any added since contract v1.0). Re-verified 2026-05-28 against `BojRest.Router`; the `POST /cartridge/:name/sse` route (router.ex line 130, wired since the SSE landing — ADR-0013 §6, STATE entry 2026-05-18) was the only drift since contract v1.0 and is now governed by the `cartridge-sse-post` rule alongside `cartridge-invoke-post` (boj-server#165).
- [x] Live policy file (`config/gateway-policy-boj.yaml`) promoted from the example. Content-identical to the example at promotion time; future BoJ-surface evolution lands in the live file and the example remains as the worked-example artefact (Phase A A3). Both §2.1 staging and §3.1 production load the live file via `POLICY_PATH`.
- [ ] Gateway has been smoke-tested in isolation with the policy, returning expected allow/deny on each route. Run `scripts/hcg-policy-smoke.sh --gateway-url <staging-gateway-url>` against the gateway loaded with `config/gateway-policy-boj.yaml`; the script exercises a no-trust-header deny probe for every non-public route (25 in the live policy), six default-deny verb canaries — DELETE/PUT/PATCH on listed exact paths, OPTIONS on a listed path (no CORS-preflight bypass), DELETE on a regex-matched route (no per-verb regex regression), and GET on the POST-only `ssg-mcp-webhook` public route (the `{path, verb}` pairing must be enforced even when the path itself is in the policy) — a path canary (GET on a synthetic `/__phase-e-canary-unknown-path__` URL that matches no exact rule, no regex rule, and no public exception) which isolates the no-match → default-deny branch of the gateway's three-tier lookup, and four stealth-profile canaries (two internal+stealth routes pinned to exactly 404, two authenticated routes pinned to exactly 403) which catch a `:stealth_profiles` misconfiguration that would otherwise let an internal route silently regress to 403 — leaking capability existence to untrusted callers, the exact threat called out in the `sdp-status-get` narrative — while still satisfying the generic any-4xx deny pattern; the verb canaries cover the unknown-method path, the path canary covers the unknown-path path, and the stealth canaries cover the deny-status-code shape, all three failing closed on independent code branches. The whole script is fully gateway-internal — BoJ does **not** need to be reachable for this run. Once BoJ is up behind the gateway, re-run with `--with-backend` from a trusted-proxy IP (loopback by default) to also cover the allow path on authenticated/internal routes including the `POST /cartridge/:name/sse` authenticated/untrusted pair carried over from boj-server#165's test plan. Attach the script's PASS/FAIL summary to the cut-over ticket; a single FAIL is a stop-the-rollout condition (gateway loaded the policy but is not enforcing as declared, or BoJ is unreachable from the gateway, or the script is being run from a non-trusted-proxy IP and the trust header is being stripped).

---

## 2. Staging cut-over

Sequencing follows plan §E2/§E3.

### 2.1 Deploy gateway in front of BoJ staging

1. Confirm BoJ staging is on the loopback bind (`:7700`) per Phase A contract §1.
2. Start the gateway with:
   - `POLICY_PATH=config/gateway-policy-boj.yaml` (live file promoted in §1.5; the example `gateway-policy-boj-example.yaml` is retained for documentation only)
   - `BACKEND_URL=http://127.0.0.1:7700`
   - `PORT=8443` (TLS) or `PORT=8080` (HTTP behind Cloudflare Tunnel)
   - `MTLS_CA_CERT_PATH=` _(staging value — !OWNER: fill)_
3. Trust source: start with `"header"` (per plan §E2). Switch to `"mtls"` after the staging cert-rotation runbook walkthrough (§2.4) completes.
4. Verify the gateway answers on its bound port and proxies to BoJ:
   ```bash
   curl -sk https://<staging-host>:8443/health
   # Expect: BoJ /health response, with gateway latency overhead within Phase D baseline + tolerance.
   ```

### 2.2 Telemetry verification (plan §E3)

- [ ] `[:http_capability_gateway, :access_decision]` events appear in the gateway's Prometheus scrape at `/metrics`.
- [ ] `GET /api/v1/minikaran` returns `status.status: "active"` after the learning phase. _(Per plan §E3; verify the endpoint path against current gateway code at rollout time.)_
- [ ] Structured JSON logs from the gateway carry `request_id`; BoJ structured logs carry the same `request_id` for the corresponding upstream request (the contract §2 cross-correlation guarantee).
- [ ] `X-Trust-Level` header arrives at BoJ correctly (read from BoJ access logs); seam test still green.
- [ ] BoJ-side §3 invariant 3 still in force — a deliberate non-loopback forged-header request to BoJ's `:7700` (only possible from within the host's loopback namespace during this test) returns `:public` decision, not the forged class. _(This is paranoia-test; the back-side bind isolation in §1.4 should already make it impossible to reach `:7700` from outside the pod.)_

### 2.3 Soak test — 24 hours minimum

Per plan §Phase E acceptance: "Gateway handles a declared traffic profile in staging for at least 24 hours without circuit breaker trips or elevated error rates."

- [ ] Drive synthetic traffic mirroring expected production mix (mix profile: !OWNER:).
- [ ] Watch the dashboards in §4 throughout. Any circuit-breaker trip or elevated 5xx aborts the rollout — file a follow-up issue, do not paper over.
- [ ] Sample p99 latency at 30-minute intervals; compare against Phase D baseline + tolerance. Within budget: pass. Outside: stop and escalate to Phase D (the budget is wrong) or Phase B/C (the gateway has a perf defect).

### 2.4 Rollback rehearsal in staging

Per plan §Phase E acceptance: "Rollback runbook exists and **has been tested** (manually walk through E5 once in staging before production rollout)."

- [ ] Walk §5.2 (immediate bypass) procedure end-to-end in staging.
- [ ] Confirm traffic returns to BoJ-direct cleanly (no dropped connections beyond expected drain time).
- [ ] Walk §5.3 (permanent disable) procedure end-to-end in staging.
- [ ] Document elapsed time for each step; if a step is slower than its rollback-trigger threshold in §5.1, redesign before production.

---

## 3. Production rollout — percentage split

Per plan §E4. Each step requires the prior step's success-criteria green for the documented soak window. Do not compress.

### 3.1 Phase 3a — 10% traffic

- [ ] Pre-step: §1 + §2 fully green. Last 24-hour staging soak ended ≤24 hours ago.
- [ ] Shift 10% of production traffic through the gateway using the !OWNER:-chosen mechanism.
- [ ] Soak window: 24 hours minimum.
- [ ] Success criteria:
  - p99 latency at production endpoints within Phase D baseline × 1.5 (the perf-regression p99 tolerance).
  - 5xx rate not elevated vs the BoJ-direct baseline (same 24-hour window the previous day).
  - No circuit-breaker trips on the gateway.
  - No `X-Trust-Level` mismatches in BoJ access logs (gateway should be the only source).
- [ ] Sign-off: !OWNER: + on-call confirm before moving to 3b.

### 3.2 Phase 3b — 50% traffic

- [ ] Shift to 50% via the same mechanism.
- [ ] Soak window: 24 hours minimum.
- [ ] Same success criteria as §3.1 with the higher sample size; investigate any drift, including drift visible only at 50% scale (saturation, head-of-line blocking).
- [ ] Sign-off before 3c.

### 3.3 Phase 3c — 100% traffic

- [ ] Shift to 100%. The BoJ direct path remains warm (not yet decommissioned).
- [ ] Soak window: 7 days. During this window, rollback (§5) is still cheap because the BoJ direct path is still wired.
- [ ] Success criteria as §3.1 plus: no escalations during business hours; no on-call pages tied to gateway behaviour.

### 3.4 Phase 3d — Decommission BoJ direct external access

- [ ] After §3.3 success window expires cleanly, close any remaining external route to BoJ's `:7700` / `gnosis.sock` so the gateway is the only ingress.
- [ ] Confirm by attempting to reach BoJ directly from a non-pod host — must fail at the network/socket layer, not just at trust enforcement.
- [ ] This step makes rollback (§5) more expensive (re-opening the direct path is now a config change). Beyond this point, "rollback" defaults to traffic-shift via the gateway's bypass plug, not network re-routing.

---

## 4. Observability — what on-call watches

> **!OWNER:** dashboard URLs and on-call rota go here. The signals below are the *what*; the *where* is owner-specific. The PromQL queries that turn each signal into a dashboard panel or alert rule live in [`gateway-observability-spec.md`](gateway-observability-spec.md) (§§ 2–5), anchored to the gateway-emitted Prometheus metrics declared in `http-capability-gateway/lib/http_capability_gateway/application.ex` `telemetry_metrics/0`.

### 4.1 Signals (gateway-side)

- p50/p95/p99 latency per scenario (health / policy-deny fast-path / proxy allow).
- Throughput (ips, per scenario).
- Circuit-breaker state (closed / half-open / open).
- 5xx rate emitted by the gateway (gateway-origin 5xx vs BoJ-passthrough 5xx — keep these distinguishable).
- Policy reload counter (a spike during stable operation is a misconfiguration alarm).
- Trust-level decision distribution (`untrusted` / `authenticated` / `internal`). Sudden shift indicates auth pipeline change.

### 4.2 Signals (BoJ-side)

- Per-route trust-class distribution from `BojRest.Router` decisions.
- `X-Trust-Level` arriving from non-loopback peers — should be zero. Any non-zero is a deployment defect (back-side bind exposed).
- BoJ 5xx rate (independent of gateway's view).

### 4.3 Dashboards

- !OWNER: Gateway dashboard URL: __________
- !OWNER: BoJ dashboard URL: __________
- !OWNER: Cloudflare zone analytics (if used for the split): __________

### 4.4 On-call

- !OWNER: Primary on-call during rollout (handle + escalation channel): __________
- !OWNER: Secondary: __________
- !OWNER: Pager runbook for "gateway in degraded state" alert: __________

---

## 5. Rollback

### 5.1 Rollback triggers

Any one of these triggers an **immediate** §5.2 bypass. No discussion in the moment; debrief afterwards.

- p99 latency at the rollout edge ≥ 2× Phase D baseline p99 for ≥ 5 minutes.
- Gateway-origin 5xx rate ≥ 1% of requests for ≥ 5 minutes.
- Circuit breaker trips ≥ 3 times in any 15-minute window.
- BoJ access logs show `X-Trust-Level` from non-loopback peers (a §3 invariant 4 violation in flight — the back-side bind is exposed).
- VeriSimDB / audit-trail write failures ≥ 1% (audit posture broken; HCG fail-closed should already be denying traffic, but verify and bypass to stop bleeding).
- On-call judgement: any user-visible regression that the on-call cannot rule out as gateway-caused within 10 minutes.

### 5.2 Immediate bypass (rollout-time, before §3.4 decommission)

While BoJ direct path is still warm:

1. Trigger the !OWNER:-chosen traffic-shift mechanism to route 100% back to BoJ-direct.
   - **Cloudflare Tunnel**: re-point the tunnel rule from gateway to BoJ direct.
   - **Container orchestration**: scale gateway deployment to 0 OR re-route the service VIP.
   - **Cloudflare percentage split**: set gateway weight to 0.
2. Confirm shift took effect via the dashboards in §4. p99 should recover toward the BoJ-direct baseline within seconds.
3. Leave the gateway processes running (do not kill) — they may still serve any in-flight requests; killing them mid-bypass costs error responses.
4. File an incident issue with: trigger criterion, time, dashboards-attached, rollback duration, and a request to re-investigate the Phase D number or the gateway behaviour that caused the trip.
5. Resume from §3.1 only after the root cause is fixed and re-staged through §2.

### 5.3 Permanent disable

If the rollback in §5.2 escalates to "do not re-attempt with this gateway version":

1. Remove the gateway k9-svc deployment per its spec at `container/gateway-deploy.k9.ncl`.
2. Update `Trustfile.a2ml [CLOUDFLARE_EDGE_SECURITY].rate_limiting.tier_2_gateway.status` to `"DISABLED — see incident <issue-id>"` (replace the placeholder `"PENDING — http-capability-gateway wiring forthcoming"` only if it was already flipped to `"DEPLOYED"` per §6.4; otherwise leave `PENDING` and just record the incident).
3. Confirm BoJ direct path is again the primary externally-addressable surface (only valid if §3.4 decommission has not yet happened; otherwise restoration requires reopening the BoJ direct path).
4. Open a Phase E re-entry issue under `standards#100` documenting why this gateway version was rejected, what the next gateway version must change before Phase E re-attempts, and any contractile updates required.

### 5.4 Post-§3.4 rollback (decommission already executed)

Once the BoJ direct path is decommissioned (§3.4), rollback is more expensive:

1. The §5.2 traffic-shift target no longer exists. Either:
   - (a) **Restore the direct path**: this is a config change (open the firewall / re-add the route) and takes minutes to hours depending on the !OWNER: traffic-shift mechanism. Estimated reversal time: __________ (!OWNER:).
   - (b) **Stay on the gateway with a known-good policy**: roll the gateway *back* to the last-known-good HCG version (the previous `.ctp`) without removing it. This is faster than (a) but only resolves gateway-version regressions, not gateway-architecture regressions.
2. Choose (a) only if the issue is gateway-architectural (e.g., HCG is the wrong tier-2). Choose (b) for code-regression issues.

---

## 6. Post-rollout verification + Trustfile flip

The acceptance criteria of `standards#100` close out here.

### 6.1 Telemetry-green window

- [ ] §3.3 soak window (7 days at 100%) completed with all signals in §4 nominal.

### 6.2 SLA confirmation

- [ ] Production p99 latency ≤ Phase D baseline p99 × 1.5 (the perf-regression p99 tolerance). If higher: re-baseline (Phase D rebaseline ritual per `http-capability-gateway/docs/perf-contract.md`) before declaring done.

### 6.3 Rollback evidence

- [ ] The §2.4 staging rehearsal and any §5.2 production bypass (planned drill or otherwise) are recorded with timestamps and outcome. The runbook has been exercised, not only written.

### 6.4 Trustfile flip — final action

Edit `.machine_readable/contractiles/trust/Trustfile.a2ml` line ~900:

```yaml
tier_2_gateway:
  provider: "http-capability-gateway / svalinn"
  mechanisms: ["per-IP token-bucket sliding window", "per-capability-token", "per-endpoint"]
  status: "DEPLOYED"
  deployed_at: "<ISO-8601 timestamp of §3.3 sign-off>"
  deployment_evidence:
    - "standards#100 close-out comment <link>"
    - "incidents (planned + unplanned) <links>"
```

Also update `[HTTP_CAPABILITY_GATEWAY]` section per plan §E acceptance: `status: "DEPLOYED"` with `deployed_at` timestamp.

### 6.5 Channel close-out

- [ ] Post a closure comment on `standards#100` summarising what landed, linking the runbook, the §6.4 commit, and any incidents.
- [ ] **Do not** self-close `standards#100`; joint-close is owner-only per the single-lane channel discipline.
- [ ] **Do not** self-close `idaptik#77`; surface that it is now closable (K9 Dogfood gate flipped green) and let the owner act.

---

## Appendix A — Glossary

- **HCG** — `hyperpolymath/http-capability-gateway`, the Elixir/Cowboy/Plug HTTP-governance layer that sits between Cloudflare edge (tier 1) and BoJ's gnosis handler (tier 3).
- **BoJ** — `hyperpolymath/boj-server`, the consumer of HCG.
- **Tier 2** — the placement of HCG in the four-tier rate-limit architecture declared in `Trustfile.a2ml [CLOUDFLARE_EDGE_SECURITY].rate_limiting`.
- **§3 invariant 3** — the Phase A contract requirement that BoJ ignores `X-Trust-Level` from any non-loopback caller. Enforced both gateway-side (header strip) and BoJ-side (`TrustPolicy.satisfies?/3` deny clause).
- **`.ctp`** — cerro-torre signed container bundle format.

## Appendix B — Cross-references

- `docs/decisions/0004-adopt-http-capability-gateway.md` — ADR.
- `docs/integration/http-capability-gateway-plan.md` — full phased plan (§Phase E sourced here).
- `docs/integration/http-capability-gateway-boj-contract.md` — HTTP boundary contract.
- `docs/integration/http-capability-gateway-policy-authoring.md` — policy file authoring workflow.
- `docs/integration/gateway-observability-spec.md` — Phase E PromQL templates + alert-threshold bindings for the §4 signals + §5 rollback triggers.
- `docs/integration/boj-side-observability-spec.md` — Phase E §1.4 prerequisite spec: BoJ-side telemetry events, Prometheus metric names, and `BojRest.Router` instrumentation sites that back the §4.2 BoJ-side signals.
- `http-capability-gateway/docs/perf-contract.md` — Phase D perf-contract.
- `elixir/lib/boj_rest/trust_policy.ex` — `satisfies?/3` Phase C enforcement.
- `.machine_readable/contractiles/trust/Trustfile.a2ml` — `[CLOUDFLARE_EDGE_SECURITY].rate_limiting.tier_2_gateway` (current `PENDING` site; §6.4 flip target) + `[SEAMS]` (Phase C gateway↔BoJ-gnosis declaration).
- `scripts/hcg-policy-smoke.sh` — §1.5 operator pre-check: deny-path smoke (gateway-alone) + optional `--with-backend` allow-path smoke against the live policy.
