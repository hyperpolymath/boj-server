<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# PROOF-NEEDS.md — boj-server

> **See also**: [`docs/proof-debt.md`](docs/proof-debt.md) is the
> schema-conformant per-repo index under the estate
> [Trusted-Base Reduction Policy](https://github.com/hyperpolymath/standards/blob/main/docs/TRUSTED-BASE-REDUCTION-POLICY.adoc)
> (standards#203, enforcement standards#211). PROOF-NEEDS.md is the
> *strategic-goals* narrative — full audit table, classification
> rationale, and external-validation pointers. `docs/proof-debt.md` is
> the *machine-checked* index that `scripts/check-trusted-base.sh`
> greps. Keep both in sync when the marker count in
> `src/abi/Boj/SafetyLemmas.idr` changes.

## Build Verification (2026-06-13) — full sweep, freshly built toolchain

Re-verified end-to-end on a clean machine with a from-source toolchain
(Idris2 0.8.0 bootstrapped via Chez Scheme 9.5.8 + libgmp), not a
desk-read of the prior entry. Three checks, all green:

- **Core ABI:** `cd src/abi && idris2 --typecheck boj.ipkg` → 17/17
  modules clean, exit 0 (~6.5 s).
- **Full proof gate:** `bash scripts/typecheck-proofs.sh` → **PASS=105
  FAIL=0** (core package + all 104 cartridge ABIs) under the pinned
  toolchain (~80 s). This is broader than the 2026-06-03 entry, which
  exercised only the core package.
- **Trusted base:** `bash scripts/check-trusted-base.sh` → PASS,
  **exactly 5** sanctioned class-(J) axioms in `SafetyLemmas.idr`, zero
  undocumented unsound constructs. Independently corroborated by a
  `panic-attack assail` scan (MPL-2.0, built from source), which flags
  the same 5 `believe_me` as `ProofDrift` and nothing else proof-shaped.

The axiom budget and theorem statements are unchanged from the
2026-06-03 entry; this checkpoint records that the **full cartridge
sweep** (not just the core package) compiles, so a future reader sees a
build-backed number rather than an inherited claim.

## Build Verification (2026-06-03)

The full core ABI package now type-checks under the pinned toolchain
(**Idris2 0.8.0**, Chez backend) — `cd src/abi && idris2 --typecheck boj.ipkg`
builds all **17** modules clean. A re-verification on this date found six
modules that the package build had never actually exercised (the `just
typecheck` recipe used an invalid `--check --package boj boj.ipkg`
invocation, and `CartridgeDispatch`/`APIContractCoverage` were absent from
`boj.ipkg`). The fixes were purely in the proofs' construction — **theorem
statements and the axiom budget are unchanged**:

- `CartridgeDispatch` — `with`-clause syntax (0.8.0 needs the full LHS or
  `_ |`); `dispatch` factored through a reducible helper so refused-
  completeness is provable; conjunction/`Uninhabited` lemmas replace the
  earlier `absurd` shortcuts.
- `SafePromptInjection`, `SafeCORS` — `with`-abstraction rewrites the goal
  to `True = True`, so the residual obligations are `Refl`.
- `SafeHTTP` — missing `Data.List.Elem`/`Data.Maybe` imports, `IsJust`→
  `isJust`, `all`→`allRec` (to match the `SafetyLemmas` lemmas), and
  explicit `{xs, ys}` binders (auto-generalised implicits are erased).
- `SafeWebSocket` — `FrameSizeSafe` is now `FrameSizeSafeUpTo maxFrameSize`
  over a new bound-parameterised family. Baking the 16 MiB `maxFrameSize`
  literal directly into a constructor's `LTE` index forced it into a unary
  Nat and exhausted the elaborator; keeping the bound symbolic in the
  constructor (and applying it in a synonym) fixes this with no loss of
  strength.
- `APIContractCoverage` — `representativeCatalogue` in a signature was being
  auto-bound as a fresh implicit (shadowing the global); fully qualified.
- `SafetyLemmas` — added the constructive lemma `allTake` (used by the
  header/delimiter `take` proofs). No new axioms.

`just verify-no-believe-me` was also reconciled: it had enforced *zero*
`believe_me`, which contradicts the sanctioned 5-axiom trusted base; it now
permits exactly the 5 `%unsafe` class-(J) axioms in `SafetyLemmas.idr` and
fails on anything else (or on axiom-count drift).

## Current State (Updated 2026-06-03)

- **src/abi/Boj/**: 17 Idris2 ABI files
- **Dangerous patterns**: **5** `believe_me` invocations, **all** in
  `src/abi/Boj/SafetyLemmas.idr`, **all** classified `(J)` genuinely
  unavoidable (see audit table below). `logSafeBounded` (SafeAPIKey.idr)
  consumes these structurally and contains no direct `believe_me` —
  down from 31 historically.
  - Note: a raw `grep believe_me *.idr` returns **9** hits. 4 of these
    are documentation/comment mentions of the word (1 in SafeHTTP.idr
    line 15, 1 in SafetyLemmas.idr line 9, 2 in
    cartridges/fleet-mcp/abi/FleetMcp/SafeFleet.idr lines 14 & 34) and
    are **not** axiom uses. The audited true count is 5.
- **LOC**: ~5,400 (Elixir + Idris2)
- **ABI layer**: Comprehensive dependent-type ABI

## Axiom Audit (2026-05-18)

Every real `believe_me` invocation, with its classification.
Classification key: **(J)** genuinely unavoidable, documented as an axiom;
**(R)** replaceable with a real proof / total definition;
**(S)** stub/laziness to fix.

| # | Site | Function | Type | Class | Rationale |
|---|------|----------|------|-------|-----------|
| 1 | `SafetyLemmas.idr:60` | `charEqSound` | `(c1,c2:Char) -> c1 == c2 = True -> c1 = c2` | **J ✓** | `Char` is an opaque primitive; `==` is `prim__eqChar` (foreign `Bool`). Idris2 0.8.0 has no in-language soundness principle for primitive equality. Standard, well-understood axiom. **Externally validated** via backend-assurance harness (`docs/backend-assurance/prim__eqChar.md` + BEAM property test). |
| 2 | `SafetyLemmas.idr:67` | `charEqSym` | `(x,y:Char) -> (x == y) = (y == x)` | **J ✓** | Symmetry of `prim__eqChar`. Same reason as #1 — opaque primitive, no decision procedure to recurse on. **Externally validated** (same harness as #1). |
| 3 | `SafetyLemmas.idr:218` | `unpackLength` | `length (unpack s) = length s` | **J ✓** | `unpack` = `prim__strToCharList` (foreign). `String` is opaque with no induction principle; the relation between primitive `String` length and `List Char` length is not reducible in-language. **Externally validated** via backend-assurance harness (`docs/backend-assurance/prim__strToCharList.md` + BEAM property test). |
| 4 | `SafetyLemmas.idr:226` | `appendLengthSum` | `length (s ++ t) = length s + length t` | **J ✓** | `++` on `String` = `prim__strAppend` (foreign). Length additivity is a backend-semantics guarantee, not type-level reducible. **Externally validated** via backend-assurance harness (`docs/backend-assurance/prim__strAppend.md` + BEAM property test). |
| 5 | `SafetyLemmas.idr:233` | `substrLengthBound` | `LTE (length (substr start len s)) len` | **J ✓** | `substr` = `prim__strSubstr` (foreign). The "result no longer than `len`" bound is a primitive-semantics guarantee with no in-language proof. **Externally validated** via backend-assurance harness (`docs/backend-assurance/prim__strSubstr.md` + BEAM property test). |

**Verdict: 5/5 are class (J).** All five reduce to the same root cause:
Idris2 treats `Char` and `String` as opaque primitive types whose
operations are foreign functions with no constructors and no induction
principle. There is no constructive in-language proof for any of them; a
`believe_me` (or an equivalent `%foreign` postulate) is the only option
short of changing the trusted computing base. They are correctly marked
`%unsafe`, individually documented, and isolated in one module.

The **J ✓** marker indicates the axiom is class (J) **and**
externally validated by the backend-assurance harness (see
`docs/backend-assurance/`). The validation does not change the
in-language proof — the `believe_me` sites stay in source. It shrinks
the trusted base from "we trust the backend" to "we have read the
backend lowering and randomly tested the operation against the
claimed property". A bare **J** indicates a class-(J) axiom whose
harness has not yet landed.

No **(R)** or **(S)** sites were found. The audit's "9" was a raw text
count conflating 5 real axioms with 4 comment mentions.

## Completed Proofs

| File | Covers | REQUIREMENTS-MASTER.md |
|------|--------|------------------------|
| `src/abi/Boj/SafePromptInjection.idr` | 6 properties preventing LLM prompt escape | — |
| `src/abi/Boj/SafeCORS.idr` | Mutually exclusive wildcard/credentials; origin char validation | — |
| `src/abi/Boj/SafeAPIKey.idr` | Entropy bounds, format safety, log-masking, timing-safe checks | BJ2 partial ✅ |
| `src/abi/Boj/SafeWebSocket.idr` | Frame length bounds, opcode validation | — |
| `src/abi/Boj/SafeHTTP.idr` | Path traversal prevention, header sanitisation | BJ2 partial ✅ |
| `src/abi/Boj/Federation.idr` | Handshake authenticity and non-replayability | — |
| `src/abi/Boj/Catalogue.idr` | IsUnbreakable: only Ready cartridges mountable | — |
| `src/abi/Boj/CartridgeDispatch.idr` | Dispatch type safety: protocol-match + readiness guard + disjointness | BJ1 ✅ |
| `src/abi/Boj/CredentialIsolation.idr` | Per-cartridge vault partitioning; cross-partition non-interference (`vaultIsolation`) | BJ2 ✅ CLOSED |
| `src/abi/Boj/APIContractCoverage.idr` | Protocol compliance (NonEmpty protocols), 15-domain coverage, 7-protocol coverage | BJ3 ✅ CLOSED |

## What Still Needs Proving

All P1/P2 proof obligations are now closed.

| # | Component | Status |
|---|-----------|--------|
| BJ2 | Auth/credential handling — full isolation model | ✅ DONE (`CredentialIsolation.idr`) |
| BJ3 | API contract compliance — protocol/domain coverage | ✅ DONE (`APIContractCoverage.idr`) |

### Remaining axiomatic surface (5 believe_me, all in SafetyLemmas.idr)

All five are class **(J)** — genuinely unavoidable in Idris2 0.8.0
(opaque `Char`/`String` primitives, foreign-backed operations). See the
**Axiom Audit (2026-05-18)** table above for per-site detail.

| Axiom | Site | Justification | Backend-assurance evidence |
|-------|------|---------------|----------------------------|
| `charEqSound` | `SafetyLemmas.idr:60` | Soundness of `prim__eqChar` — backend primitive correctness, externally validated | `docs/backend-assurance/prim__eqChar.md` + `elixir/test/backend_assurance/prim_eq_char_test.exs` |
| `charEqSym` | `SafetyLemmas.idr:67` | Symmetry of `prim__eqChar` — backend primitive correctness, externally validated | `docs/backend-assurance/prim__eqChar.md` + `elixir/test/backend_assurance/prim_eq_char_test.exs` |
| `unpackLength` | `SafetyLemmas.idr:218` | `prim__strToCharList` preserves length — backend primitive correctness, externally validated | `docs/backend-assurance/prim__strToCharList.md` + `elixir/test/backend_assurance/prim_str_to_char_list_test.exs` |
| `appendLengthSum` | `SafetyLemmas.idr:226` | `prim__strAppend` length semantics — not reducible at type level, externally validated | `docs/backend-assurance/prim__strAppend.md` + `elixir/test/backend_assurance/prim_str_append_test.exs` |
| `substrLengthBound` | `SafetyLemmas.idr:233` | `prim__strSubstr` length bound — not reducible at type level, externally validated | `docs/backend-assurance/prim__strSubstr.md` + `elixir/test/backend_assurance/prim_str_substr_test.exs` |

Note: `logSafeBounded` in SafeAPIKey.idr no longer uses `believe_me` directly;
it calls the documented SafetyLemmas axioms via structural proof.
`charEqSound` is consumed by `Safety.idr` (`shellContra`, `sqlContra`);
`unpackLength` by `SafeAPIKey.idr` (`sufficientEntropyNonEmpty`).

### Backend-assurance harness

The "Backend-assurance evidence" column above cites the external
evidence reducing each class-(J) axiom's trusted base. Two artefact
shapes per primitive:

- **Trusted-extraction validation** under `docs/backend-assurance/<primitive>.md`
  — prose argument citing each shipping backend's lowering of the
  primitive (Idris2 0.8.0 sources for Chez, OTP/R6RS for the runtime
  operations) and why the lowering satisfies the axiom.
- **Property-test harness** under `elixir/test/backend_assurance/`
  — BEAM-native property tests via `stream_data` covering the
  codepoint / string spaces. Run via `mix test --only backend_assurance`
  and gated in CI by `.github/workflows/backend-assurance.yml`.

This harness does not change the in-language proof — the `believe_me`
sites stay in `SafetyLemmas.idr`. The harness shrinks the trusted base
from "we trust the backend" to "we read the lowering and randomly
tested the operation".

Primitives validated so far: `prim__eqChar` (covering `charEqSound`
and `charEqSym`), `prim__strToCharList` (covering `unpackLength`),
`prim__strAppend` (covering `appendLengthSum`), and `prim__strSubstr`
(covering `substrLengthBound`). Tracked under epic #87 Tier C
backend-assurance campaign.

## Priority Going Forward

**LOW** — All named proof obligations closed. Future work:
- Proofs for Dap/Bsp/CodeIntel domains when those cartridges reach Ready status
- Proof that `dispatch` is surjective onto all BJ3-covered (domain, protocol) pairs
- The 5 string/char-primitive axioms are **irreducible within Idris2**
  (opaque primitive types). They cannot be "proved away" in-language;
  the only reduction path is to shrink the trusted base by validating
  `prim__eqChar` / `prim__strToCharList` / `prim__strAppend` /
  `prim__strSubstr` against the chosen backend (Chez/BEAM) via an
  external trusted-extraction or property-test harness, then citing
  that evidence here. This is a backend-assurance task, not a proof
  obligation — keep it tracked but do not expect a constructive proof.
