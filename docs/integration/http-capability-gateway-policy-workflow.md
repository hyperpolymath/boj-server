<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Verb Governance Spec — Authoring & Lifecycle Workflow

**Version:** 1.0  
**Date:** 2026-05-17  
**Status:** Phase A deliverable A2 (Policy authoring workflow)  
**Plan:** `docs/integration/http-capability-gateway-plan.md` (Phase A, A2)  
**Contract:** `docs/integration/http-capability-gateway-boj-contract.md` (A1)  
**Example:** `config/gateway-policy-boj-example.yaml` (A3)

---

## 1. Where the policy lives

The Verb Governance Spec is a **BoJ-repo artefact**. It lives in this
repository at:

```
config/gateway-policy.yaml          # the live BoJ policy (added in Phase E)
config/gateway-policy-boj-example.yaml   # the worked example (Phase A, A3)
```

Rationale (resolves the Phase A A2 question): the policy *describes BoJ's HTTP
surface*, so it is version-controlled alongside `docs/specification/openapi.yaml`
and reviewed by the same people who own that surface. It is **not** kept in the
gateway repository — the gateway is a generic governance engine; the policy is
BoJ-specific data the gateway loads at runtime.

Until Phase E, only the `-example` file exists. No running service loads it;
it is a worked reference and a validation fixture.

## 2. Who writes it, and the review gate

- **Author:** the BoJ maintainer who owns the HTTP surface change.
- **Review:** a policy change is a spec change. It requires a PR, reviewed and
  approved like any change to `docs/specification/openapi.yaml`.
- **Coupling rule (normative):** when `openapi.yaml` changes in a way that
  adds, removes, or changes the trust posture of a route, the same PR MUST
  update `config/gateway-policy.yaml`, **or** the PR description MUST state why
  the policy is unchanged (e.g. “new route is internal-only and already
  covered by the `/admin` internal rule”). This mirrors the cross-phase note
  in the integration plan and the Trustfile `[SEAMS]` policy
  (`every PR that touches either side of a declared seam MUST exercise the
  seam test`).

## 3. DSL v1 shape (normative reference)

The authoritative schema is the gateway's `PolicyValidator` (integration audit
§1.2 and §2). Summary:

- `dsl_version` — required; MUST be exactly `"1"` (string).
- `governance.global_verbs` — required; non-empty list of upper-case HTTP
  verbs. **Sharp edge (see §6):** global verbs compile to a `{:global, verb}`
  fallback rule with `exposure: "public"`. Keep this list minimal.
- `governance.routes` — optional; list of per-route rules. Each route:
  - `path` — required; literal string **or** a valid regex. Patterns
    containing regex metacharacters are compiled into the regex table
    (O(r) scan); literal paths go to the exact table (O(1)).
  - `verbs` — required; non-empty list of HTTP verbs (overrides global for
    this path).
  - `exposure` — optional; one of `public` | `authenticated` | `internal`.
  - `stealth_profile`, `narrative`, `backend`, `name` — optional.
- `stealth` — optional; if present, MUST have `enabled` (boolean) and
  `status_code` (integer 100–599).

The `narrative` field is not optional *by convention* for BoJ: every BoJ route
rule SHOULD carry a one-line `narrative` explaining the trust decision, so the
policy file is self-documenting and the audit log carries the rationale.

## 4. How it is validated

Before a policy PR merges, the file MUST pass the gateway's loader and
validator. From a checkout of `web-ecosystem/http-capability-gateway`:

```bash
# manual verification (Phase A acceptance for A3)
iex -S mix
iex> {:ok, p} = HttpCapabilityGateway.PolicyLoader.load_policy(
...>   "/path/to/boj-server/config/gateway-policy-boj-example.yaml")
iex> :ok = HttpCapabilityGateway.PolicyValidator.validate(p)
```

Phase C formalises this as an automated check; Phase A requires only the
manual run above. The example file (A3) is authored to pass it.

## 5. Load and hot-reload at deploy

- **Load path:** the gateway container reads the policy from the path given by
  the `POLICY_PATH` environment variable. BoJ mounts
  `config/gateway-policy.yaml` at that path (bind-mount or ConfigMap; decided
  in the Phase E deployment spec).
- **Hot-reload:** the gateway compiles the new policy into a fresh ETS table
  pair and swaps it atomically; a compile failure leaves the last-known-good
  policy in force (audit §1.3). The reload trigger for BoJ is a **k9-svc
  rolling redeploy** of the gateway container (Trustfile
  `[CONTAINER_SUPPLY_CHAIN].deployment`, `k9-svc`). A signal-based
  (`SIGHUP`-style) in-place reload is available in the gateway but is **not**
  the BoJ-sanctioned path — rolling redeploy keeps the policy change inside
  the normal signed-deploy pedigree rather than a side channel.

## 6. Sharp edge: `global_verbs` is a public fallback — keep BoJ default-deny

`global_verbs` is required and non-empty, and each global verb compiles to a
fallback rule with `exposure: "public"`. The lookup order is exact → regex →
global. So a request whose path matches no explicit rule but whose verb is in
`global_verbs` would be allowed **as public**.

For BoJ this is the opposite of the desired default-deny posture. The BoJ
policy therefore:

1. Keeps `global_verbs` as small as the validator allows (a single verb).
2. Enumerates every intended route explicitly with an `exposure`.
3. Treats *any* reliance on the global fallback as a policy bug to be caught
   in review — an unmatched path reaching the public global rule means a route
   is missing from the spec, not that the route is intentionally public.
4. Enables `stealth` so denials do not advertise capability existence.

This is recorded here (Phase A) so the constraint is explicit before any
production policy is written in Phase E, and so Phase C property tests can
assert “no path outside the enumerated set is served at a trust level above
`untrusted`.”

## 7. Acceptance (Phase A, deliverable A2)

- [x] Policy location decided (`config/gateway-policy.yaml` in this repo) and
      justified (§1).
- [x] Authorship + review gate + openapi-coupling rule stated (§2).
- [x] DSL v1 schema referenced normatively (§3).
- [x] Validation procedure documented (§4).
- [x] Load + hot-reload mechanism decided (k9-svc rolling redeploy) (§5).
- [x] `global_verbs` default-public sharp edge documented with BoJ mitigation
      (§6).
