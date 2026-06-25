<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Proof Debt — boj-server

**Schema**: [hyperpolymath/standards `TRUSTED-BASE-REDUCTION-POLICY.adoc`](https://github.com/hyperpolymath/standards/blob/main/docs/TRUSTED-BASE-REDUCTION-POLICY.adoc) (standards#203).

boj-server is the **reference implementation** for the estate trusted-base
reduction policy (cited as such in standards#203). The 4 class-J axioms
this repo isolates in `src/abi/Boj/SafetyLemmas.idr` are the canonical
example of disposition §(c) NECESSARY AXIOM, and the
`docs/backend-assurance/` per-axiom files are the canonical example of
external validation under §(b)-style discipline. (A 5th former axiom,
`charEqSym`, was discharged to a constructive theorem on 2026-06-24 — the
first §(a) entry below.)

This `docs/proof-debt.md` is a thin schema-aligned index. The substantive
content lives in:

- **[`PROOF-NEEDS.md`](../PROOF-NEEDS.md)** (repo root) — full audit table
  with type signatures, classification rationale, and external-validation
  pointers.
- **[`docs/backend-assurance/`](./backend-assurance/)** — per-primitive
  property tests + BEAM-side validation evidence
  (`prim__eqChar.md`, `prim__strToCharList.md`, `prim__strAppend.md`,
  `prim__strSubstr.md`).

## (a) DISCHARGED in this repo

- **`charEqSym`** : `(x, y : Char) -> (x == y) = (y == x)` — *discharged
  2026-06-24*. Formerly a class-J axiom; now **derived constructively from
  `charEqSound`** in `src/abi/Boj/SafetyLemmas.idr`. Intuition: a `True`
  result forces propositional equality via `charEqSound`, collapsing both
  sides to the same expression; a mixed `True`/`False` split is impossible
  under soundness. Verified by `idris2 --typecheck boj.ipkg` (Idris2 0.8.0,
  17/17 modules clean). This is the first §(a) discharge and the reason the
  sanctioned count dropped **5 → 4**.

The remaining 4 class-J axioms are genuinely unavoidable in Idris2 0.8.0;
they would move here only if a future Idris2 exposes in-language soundness
principles for `Char` / `String` primitives.

## (b) BUDGETED — tested with a refutation budget

The 4 axioms below are documented under §(c) (NECESSARY) rather than §(b)
(BUDGETED) because they cannot be discharged in-language. **However**,
each one is *externally validated* via the
[backend-assurance harness](./backend-assurance/) — property tests
running against the real BEAM runtime, exercising the Erlang/Elixir
implementations of the underlying primitive operations.

This dual-discipline (axiom-in-Idris2 + property-tested-externally) is
the reference pattern the estate trusted-base policy recommends for
extraction-boundary code.

## (c) NECESSARY AXIOM

All 4 are class-J ("genuinely unavoidable") per
[PROOF-NEEDS.md §Axiom Audit](../PROOF-NEEDS.md). Each reduces to the same
root cause: Idris2 0.8.0 treats `Char` and `String` as opaque primitive
types whose operations are foreign functions with no constructors and no
induction principle. (`charEqSym` was a 5th entry here until 2026-06-24,
now discharged — see §(a).)

| # | Site (`SafetyLemmas.idr`) | Signature | External validation |
|---|------|-----------|---------------------|
| 1 | `charEqSound` | `(c1,c2 : Char) -> c1 == c2 = True -> c1 = c2` | [`docs/backend-assurance/prim__eqChar.md`](./backend-assurance/prim__eqChar.md) |
| 2 | `unpackLength` | `length (unpack s) = length s` | [`docs/backend-assurance/prim__strToCharList.md`](./backend-assurance/prim__strToCharList.md) |
| 3 | `appendLengthSum` | `length (s ++ t) = length s + length t` | [`docs/backend-assurance/prim__strAppend.md`](./backend-assurance/prim__strAppend.md) |
| 4 | `substrLengthBound` | `LTE (length (substr start len s)) len` | [`docs/backend-assurance/prim__strSubstr.md`](./backend-assurance/prim__strSubstr.md) |

Citation: see standards#203 §"Precedent" — boj-server's harness is the
reference implementation the estate trusted-base policy directs other
proof-bearing repos to adopt.

## (d) DEBT — actively to be closed

*(None in the Idris2 ABI layer. The 4 class-J axioms above are §(c),
not §(d); they are not "to be closed" — they are load-bearing
assumptions about the trusted base. `charEqSym` moved §(c) → §(a) on
2026-06-24, not via Idris2 change but because it was found to be derivable
from `charEqSound`.)*

Future work that would generate §(d) entries:

- Migration to a future Idris2 version exposing in-language soundness
  principles for primitive types — would let entries #1–#4 move from
  §(c) → §(a) via discharge.
- New `believe_me` introduced in non-SafetyLemmas.idr files — these
  must be classified as §(a)/§(b)/§(c) before merge or land here as
  §(d) with a deadline.

## How to update this file

When `src/abi/Boj/SafetyLemmas.idr` changes:

1. Cross-check against `PROOF-NEEDS.md` — keep the per-site row counts
   in sync.
2. If a new `believe_me` is introduced anywhere outside that module,
   add an entry here under §(d) or §(b) with an audit table entry in
   `PROOF-NEEDS.md`.
3. The future `scripts/check-trusted-base.sh`
   ([standards trusted-base policy](https://github.com/hyperpolymath/standards/blob/main/docs/TRUSTED-BASE-REDUCTION-POLICY.adoc))
   greps for naked `believe_me` outside `SafetyLemmas.idr` and fails CI
   if it's not annotated or enumerated here.

## Companion documents

- [`PROOF-NEEDS.md`](../PROOF-NEEDS.md) — substantive audit table.
- [`docs/backend-assurance/`](./backend-assurance/) — external-validation evidence.
- [standards#195](https://github.com/hyperpolymath/standards/pull/195) — estate proof-debt audit.
- [standards#203](https://github.com/hyperpolymath/standards/pull/203) — trusted-base reduction policy (the schema this file follows).
- Memory: `project_boj_server_backend_assurance_harness.md` — long-term reduction plan (~3 months, ~1 PR per primitive).

---

🤖 Schema-conformant index seeded by Claude Code, 2026-05-26. boj-server is the
reference implementation the estate trusted-base policy cites.
