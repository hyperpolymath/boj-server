<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# 14. Cross-cartridge composition safety — defining what we mean and how to prove it

Date: 2026-05-20

## Status

Proposed (RFC — implementation tracked in epic #87 Tier C item 12; this
ADR is the framing document, not a build plan)

## Context

The existing Idris2 ABI proves a lot for **individual** cartridges:

- `Boj.CartridgeDispatch` (BJ1) shows the dispatcher is type-safe:
  `ProtocolMatch + ReadinessGuard + Disjointness` — well-typed dispatch
  cannot route a request to a cartridge that doesn't advertise the
  protocol or that hasn't passed the safety gate (`IsUnbreakable`).
- `Boj.Catalogue` defines `IsUnbreakable` as the gate that admits only
  `Ready` cartridges.
- Per-cartridge `Safe*.idr` modules (`SafeHTTP`, `SafeCORS`, `SafeAPIKey`,
  `SafeWebSocket`, `SafePromptInjection`, `Federation`,
  `CredentialIsolation`, `APIContractCoverage`) discharge the P-01..P-07
  proof obligations local to that cartridge.

The 2026-05-18 audit (`PROOF-NEEDS.md`) records 5 remaining `believe_me`
sites, all class (J) — principled assumptions over Idris2 0.8.0's opaque
`Char`/`String` primitives. Within the per-cartridge ABI surface, the
proof debt is closed.

What is **not** proved is what happens when one cartridge calls another.
Concretely: BoJ exposes a 5th-standard-symbol Zig FFI export per
cartridge — `boj_cartridge_invoke(tool, args_json, out, out_len)` — and
the bridge happily lets cartridge A's handler call cartridge B's
`boj_cartridge_invoke` to compose tools. ADR-0006 defines the invoke
surface; ADR-0009 (sandbox cartridge, RFC-only as of this writing —
`cartridges/sandbox-mcp/` does not yet exist on disk) and ADR-0010
(cross-machine coord federation) both lean on composition without
defining what makes a composition *safe*.

We have a hole: per-cartridge invariants do not compose automatically.
If cartridge A's tool requires `IsUnbreakable` and produces JSON whose
shape satisfies its own `SafeHTTP` contract, that says nothing about
whether the resulting JSON, fed into cartridge B's
`boj_cartridge_invoke`, satisfies B's preconditions. The Idris2 type
system can only check this if the cartridges share a typed composition
boundary; today they share only bytes.

This ADR scopes the problem so a campaign can attack it.

## Decision (framing, not implementation)

Define **composition safety** for BoJ as a **two-level contract**, with
the Idris2 ABI carrying the *static* level and a Nickel-encoded policy
layer (via ADR-0007's `policy-mcp` PDP) carrying the *dynamic* level.
Discharge them in a first pair, then generalise.

### Level 1 — Static (Idris2): typed composition envelope

Introduce a new module `Boj.Composition` that lifts the per-cartridge
ABI obligations into a composition-aware envelope:

```idris
||| A typed inter-cartridge invocation.
||| Carries proofs that the source cartridge is Ready, the target
||| cartridge is Ready, the requested tool is in the target's
||| advertised tool list, and the marshalled args satisfy the target's
||| input contract.
public export
record InvocationOf (src, tgt : Cartridge) (tool : ToolName) where
  constructor MkInvocation
  srcReady  : IsUnbreakable src
  tgtReady  : IsUnbreakable tgt
  toolValid : tool `elem` advertisedTools tgt = True
  argsOk    : ArgsContract tgt tool args
```

A composition is **statically safe** iff `boj_cartridge_invoke` only
fires when the caller can construct a witness of `InvocationOf src tgt
tool`. The dispatcher (BJ1) already proves the field-2 and field-3
analogues for *external* requests; this lifts the same proofs into the
*internal* invocation path.

`ArgsContract` is the open piece — it has to be defined per-cartridge,
mirroring whatever invariants the target's local `Safe*.idr` already
encodes. For the first proof pair we propose mechanically deriving it
from each cartridge's existing JSON-schema in `cartridge.json`.

### Level 2 — Dynamic (Nickel policy contract): composition admissibility

The static envelope says *if* you can typecheck the invocation, it's
shape-safe. It does not say the invocation is *policy*-safe — e.g. a
Teranga-tier cartridge should not be allowed to invoke an
Ayo-tier cartridge in a way that elevates privilege. That's the job of
the PDP introduced by ADR-0007.

Extend `policy-mcp`'s Nickel schema with a `compositions` block:

```nickel
compositions = {
  # Allow panic-attack -> vordr (untrusted-execution flow per ADR-0009)
  "panic-attack-mcp".allows_invoking = ["vordr-mcp"],
  "panic-attack-mcp".max_call_depth = 1,
  "panic-attack-mcp".target_must_be_tier_lte = 2,

  # Deny ayo -> teranga (privilege elevation)
  "*-ayo".allows_invoking_tier_lt_self = false,
}
```

The bridge's `hardeningGate` consults the PDP on every internal
invocation, the same way it already consults it for external dispatch.

### First proof pair (recommended, with caveat)

The prompt suggested `panic-attack-mcp → sandbox-mcp → vordr-mcp` as the
canonical untrusted-execution chain. Two of the three exist on disk
today:

- `cartridges/panic-attack-mcp/` — exists
- `cartridges/sandbox-mcp/` — **does not exist**; ADR-0009 proposes
  it but no implementation has landed
- `cartridges/vordr-mcp/` — exists

Therefore the first composition pair to discharge is **`panic-attack-mcp
→ vordr-mcp`** (a real pair, both Teranga / Shield, both with extant
ABI). The three-cartridge chain remains the eventual target; sandbox-mcp
needs to be built (per ADR-0009) before the longer chain can be proved.

### What we are explicitly **not** doing

- **Not lifting all cartridges into a single shared Idris2 module.**
  That would be a multi-year refactor. `InvocationOf` is parameterised
  on `Cartridge` (already defined in `Boj.Catalogue`) and pulls the
  per-cartridge contract via a typeclass / interface, not by source-level
  unification.
- **Not making every existing cross-cartridge call retroactively
  proven.** Existing internal invocations stay on the untyped byte
  path; new ones go through `InvocationOf` once it lands. Migration is
  per-pair, prioritised by trust-tier risk.
- **Not weakening any existing single-cartridge proof.** If a P-01..P-07
  obligation conflicts with the composition envelope, the obligation is
  right and the envelope shape is wrong.

## Discharge mechanism — sub-RFCs and PRs

The campaign decomposes into roughly six sub-issues, each its own PR:

1. **`Boj.Composition` skeleton.** Define `InvocationOf`, `ArgsContract`
   as an interface, and helpers. No cartridge wired up. Build-green via
   `idris2 --check`. Refs item 12.
2. **First pair: `panic-attack-mcp → vordr-mcp` static proof.** Provide
   `ArgsContract` instances for both cartridges' tools, prove one real
   panic-attack → vordr invocation in `cartridges/panic-attack-mcp/abi/
   PanicAttackMcp/CompositionWithVordr.idr`. PR pattern: one
   `CompositionWith*.idr` per pair.
3. **Bridge wiring (PEP).** `mcp-bridge/lib/dispatcher.js` learns to
   look for a composition envelope on internal `boj_cartridge_invoke`
   calls; rejects on absence when the source/target pair is gated.
4. **`policy-mcp` `compositions` block (PDP).** Schema, fixtures,
   ADR-0007 follow-on PR.
5. **Wire-up tests** in `mcp-bridge/tests/composition_test.js` —
   property tests across the gate truth table (allowed pair, denied
   pair, depth-exceeded, tier-violation, target-not-ready).
6. **JOSS paper.** `docs/papers/joss-composition-proof.md` — the
   formal-verification differentiation of BoJ vs other MCP servers,
   with `panic-attack → vordr` as the worked example.

## JOSS paper angle

BoJ's unique posture relative to other MCP servers is the
formally-verified ABI. No other MCP server (per ADR-0008's
marketplace survey) carries an Idris2 proof layer. Submitting the
composition-proof artifact to JOSS does two things:

- Establishes priority on the framing of MCP composition as a typed
  problem.
- Provides academic citability for downstream users — the OU
  affiliation makes the route tractable.

The paper draft should be sketched **alongside** the first pair's
proof, not after, so the framing in the paper and the framing in the
code stay coherent.

## Constraints and non-negotiables

1. **Idris2 build stays green throughout.** Every PR must include a
   `idris2 --check` invocation. (Note: at time of writing, `src/abi/
   boj.ipkg --build` does not complete in 9 min on a local dev box but
   individual `--check` runs are fast. Pre-existing baseline-rot in
   `Boj.SafeAPIKey` is tracked separately; do not block composition
   work on it.)
2. **No `believe_me` net-additions.** The 5 existing axioms are
   irreducible (PROOF-NEEDS audit 2026-05-18). New axioms only via
   explicit `parameters` blocks with documented rationale.
3. **The honest count rule.** If a proof obligation in the composition
   envelope turns out to be irreducible, **document it as a principled
   assumption** rather than papering over it. The honest count is more
   valuable than a forced "zero".
4. **No cartridge invented for proof convenience.** Specifically:
   `sandbox-mcp` (ADR-0009) is RFC-only today. The campaign uses real
   cartridges (panic-attack, vordr) for the first pair; the three-step
   chain is parked behind ADR-0009 implementation.

## Definition of done

- [ ] `Boj.Composition` lands and type-checks (sub-PR 1).
- [ ] At least one composition pair proven end-to-end (sub-PR 2).
- [ ] Bridge PEP + PDP composition rules in production for that pair
      (sub-PRs 3 + 4).
- [ ] Wire-up tests pass on CI (sub-PR 5).
- [ ] JOSS paper draft submitted, with `panic-attack → vordr` as the
      worked example (sub-PR 6).
- [ ] Per-pair sub-issues filed for the next composition pairs; epic
      #87 item 12 stays open until coverage is "meaningful" (specific
      threshold TBD with the owner — likely "all destructive-side-effect
      cartridges have at least one proven invoker").

## Open questions

- **`ArgsContract` derivation strategy.** Mechanically lift from each
  cartridge's `cartridge.json` JSON-schema (cheap, brittle) vs hand-
  written per cartridge (expensive, robust) vs a Nickel intermediate
  schema (medium). Recommend deciding before sub-PR 1 lands.
- **Federation interaction.** Cross-machine invocations (ADR-0010) need
  their own composition story — the envelope has to survive
  serialisation. Punt to a follow-on ADR once the local case lands.
- **Sandbox-mcp build-out.** The full panic-attack → sandbox → vordr
  chain is the JOSS-paper-shaped goal; without sandbox-mcp it's a two-
  cartridge demo. ADR-0009 needs to be built first, or the proof scope
  needs to be honestly limited to the two-cartridge case in the paper.

## References

- ADR-0006 — cartridge-invoke ABI (defines `boj_cartridge_invoke`)
- ADR-0007 — trust-tier policy DSL (defines policy-mcp PDP that this
  ADR extends with a `compositions` block)
- ADR-0009 — sandbox cartridge (RFC-only; the missing cartridge in the
  canonical three-step chain)
- ADR-0010 — cross-machine coord federation (depends on a composition
  story; needs follow-on)
- `PROOF-NEEDS.md` — 2026-05-18 audit; the 5 class (J) axioms; closure
  of P1/P2 obligations per cartridge
- `src/abi/Boj/CartridgeDispatch.idr` — BJ1 (the existing external-
  dispatch proof that this ADR lifts into the internal-invocation
  envelope)
- Epic #87 Tier C item 12 — the campaign tracker
