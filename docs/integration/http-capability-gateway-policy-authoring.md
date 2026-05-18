<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Verb Governance Spec — Authoring & Deployment Workflow

**Version:** 1.0
**Date:** 2026-05-18
**Status:** Phase A deliverable A2 (normative)
**Plan:** `docs/integration/http-capability-gateway-plan.md` (§ Phase A, A2)
**Contract:** `docs/integration/http-capability-gateway-boj-contract.md`
**Tracking:** standards#91 (parent), standards#96 (Phase A)

This document answers the four A2 questions the plan poses: **where** the Verb
Governance Spec lives, **who** writes it, **how** it is loaded at deploy, and
**how** hot-reload is triggered — plus the review/versioning discipline that
keeps the policy from drifting away from BoJ's real HTTP surface.

---

## 1. Where the spec lives

**Decision:** the Verb Governance Spec is a **BoJ-repo artefact** at

```
config/gateway-policy-boj.yaml          # the live policy (added in a later phase)
config/gateway-policy-boj-example.yaml  # the Phase A worked example (this PR)
```

Rationale (plan A2 option 1, chosen over option 2 "separate file in the gateway
repo"): the policy *describes BoJ's HTTP surface*. It must be version-controlled
**alongside** `docs/specification/openapi.yaml` so that a change to the surface
and the change to its governance are reviewable in the same repository, ideally
the same PR (see §5). Keeping it in the gateway repo would split the surface and
its governance across two repos and two review queues — the precise drift
failure the ADR warns about ("if the policy file lags the actual surface, routes
may be default-denied").

The gateway repo remains the home of the *DSL definition and validator*; the
*instance* of that DSL for BoJ lives here.

---

## 2. Who writes it

- The Verb Governance Spec is written and changed by a **BoJ maintainer**.
- It is reviewed **like any specification change**: PR required, maintainer
  approval required. It is not a config knob that can be hand-edited on a
  deployed host — the deployed copy is immutable and comes from this repo.
- A change to `docs/specification/openapi.yaml` (the HTTP surface) and the
  corresponding change to `config/gateway-policy-boj.yaml` SHOULD land in the
  **same PR**. If they cannot, the surface PR MUST state explicitly why the
  policy is unchanged (e.g. "new route is internal-only and already covered by
  the default-deny backstop", or "route is not externally reachable").

---

## 3. How it is loaded at deploy

- The gateway container reads the policy path from the **`POLICY_PATH`**
  environment variable (per the gateway's documented configuration; the audit
  records `PolicyLoader.load_policy/1` as the load entry point).
- The policy file is delivered into the container at that path by a
  **bind-mount or k9-svc ConfigMap-equivalent**, sourced from this repo's
  `config/gateway-policy-boj.yaml`. The file is **read-only** in the container.
- Load sequence at startup (from the audit, §1.1–1.3):
  1. `PolicyLoader.load_policy/1` parses the YAML → `{:ok, map()}`.
  2. `PolicyValidator.validate/1` checks DSL v1 structural invariants.
  3. `PolicyCompiler.compile/2` builds the dual ETS tables.
  If validation fails at startup the gateway MUST refuse to start (fail-closed);
  it MUST NOT start with no policy and default-allow.

---

## 4. Hot-reload trigger

The gateway implements an **atomic compile-then-swap**: a new policy is loaded,
validated, and compiled into fresh ETS tables; only on success are the live
tables swapped. On validation/compile failure the **last-known-good policy is
preserved** and the reload is a no-op (audit §1.3).

Reload is triggered by, in order of preference:

1. **k9-svc rolling redeploy** — the standard path. A policy change is a normal
   versioned deploy: new file, new container revision, rolling restart. No
   in-place mutation. This is the **production-default** mechanism because it
   keeps the running policy provably equal to a reviewed repo artefact.
2. **SIGHUP / `gateway-reload` signal** — supported by the atomic-swap pattern
   for low-latency reloads without a full restart, used when a rolling redeploy
   is too heavy (e.g. an urgent narrowing of an over-broad rule). The reloaded
   file MUST still come from a merged repo artefact, mounted before the signal
   is sent; ad-hoc on-host edits are prohibited.

Phase C must verify that an in-flight request is **not dropped** during a
reload (plan §Phase C, C1 "policy hot-reload" case). Until that test exists,
mechanism (1) — rolling redeploy with normal connection draining — is the only
sanctioned production reload path; mechanism (2) is dev/staging only.

---

## 5. Review & versioning discipline (anti-drift)

The single largest operational risk in the ADR is **policy lagging the
surface**. The discipline that prevents it:

- **Co-change rule.** Any PR that adds, removes, or changes an HTTP route in
  `docs/specification/openapi.yaml` (or in `BojRest.Router` / the gnosis
  handler) MUST either update `config/gateway-policy-boj.yaml` in the same PR or
  carry an explicit, reviewed justification for leaving it unchanged.
- **Default-deny is a backstop, not a policy.** A route that is missing from the
  spec is denied. That is safe (fail-closed) but it is an *outage* for a route
  that should be public. Relying on default-deny instead of an explicit rule is
  a review finding, not an acceptable steady state.
- **Validation gate.** CI SHOULD run the example/live policy through the
  gateway's `PolicyLoader.load_policy/1` + `PolicyValidator.validate/1` so a
  malformed policy cannot merge. (Wiring this CI gate is Phase C/D scope; the
  Phase A acceptance criterion is a *manual* verification — see §6.)
- **Narrative is mandatory.** Every route rule carries a `narrative` explaining
  *why* that exposure level. A rule whose narrative cannot be written is a rule
  that is not understood and MUST NOT be merged.

---

## 6. Phase A verification status

The plan's Phase A acceptance criterion "example policy file passes
`PolicyLoader.load_policy/1` + `PolicyValidator.validate/1`" is a **manual
verification** performed against a running gateway. In Phase A no gateway is
deployed, so `config/gateway-policy-boj-example.yaml` is authored to **conform
exactly to the documented DSL v1 schema and `PolicyValidator` invariants**
(audit §2): `dsl_version: "1"`; `governance.global_verbs` a non-empty list of
all-caps HTTP verbs; each route with non-empty `verbs`, optional
`exposure ∈ {public, authenticated, internal}`; `stealth` with boolean
`enabled` and integer `status_code` in 100–599.

The running-gateway manual check is an explicit, recorded carry-over to be
executed when the gateway container is first stood up (Phase E E2 staging
bring-up, or earlier if the gateway is run locally). It is a verification step,
not a code deliverable, and does not block Phase A closure.
