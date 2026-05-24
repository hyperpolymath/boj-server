<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Backend-Assurance: `prim__eqChar`

Trusted-extraction validation for the two class-(J) axioms over
Idris2's `prim__eqChar` primitive:

- `charEqSound : (c1, c2 : Char) -> c1 == c2 = True -> c1 = c2`
  (`src/abi/Boj/SafetyLemmas.idr:53`)
- `charEqSym : (x, y : Char) -> (x == y) = (y == x)`
  (`src/abi/Boj/SafetyLemmas.idr:60`)

Both are `%unsafe` `believe_me` declarations in Idris2 0.8.0 because
`Char` is an opaque primitive type with no in-language induction
principle. This document argues — by inspecting the backend lowerings
that BoJ actually ships against — that the believed properties hold.

The companion property test
(`elixir/test/backend_assurance/prim_eq_char_test.exs`) exercises the
BEAM half of this argument over the codepoint space.

## What `prim__eqChar` is

`prim__eqChar : Char -> Char -> Int` is a primitive arithmetic
operation declared in `Core.Primitives` in the Idris2 compiler. The
`==` method on `Char` calls it via the `Eq Char` instance in
`Prelude.EqOrd`:

    public export
    Eq Char where
      x == y = boolOp prim__eqChar x y
      x /= y = not (x == y)

so the question reduces to: does `prim__eqChar` satisfy soundness and
symmetry on each shipping backend?

## Chez Scheme backend (Idris2 default codegen)

In `Compiler.Scheme.Chez`, `prim__eqChar` is one of the arithmetic
primitives lowered directly to the R6RS predicate `char=?` (via the
generic `op` translation table that maps `EQ CharType` to
`char=?`). On Chez 9.x:

- **Soundness.** R6RS §11.11 specifies `char=?` returns `#t` iff its
  arguments denote the same Unicode codepoint. The Char value is the
  codepoint; two Chars for which `char=?` returns `#t` are the same
  value. Hence `c1 == c2 = True -> c1 = c2` holds.
- **Symmetry.** R6RS §11.11 specifies `char=?` is a total
  equivalence relation. Symmetry is part of "equivalence relation";
  hence `(x == y) = (y == x)` holds.

Both properties are part of the Scheme standard and are upheld by the
Chez implementation. No further evidence needed beyond citing the
standard.

## BEAM backend (Erlang / Elixir, where BoJ runs)

BoJ's REST surface is Elixir on the BEAM. The Idris2 proofs are
compile-time-only artefacts; the runtime characters that flow through
the system are BEAM codepoints (Erlang integers in the range
`0..0x10FFFF` excluding the surrogate gap `0xD800..0xDFFF`). On BEAM:

- **Char encoding.** Erlang represents a character as an
  integer codepoint. Strings are either lists-of-integers ("traditional"
  Erlang strings) or UTF-8 binaries — but the per-character equality
  operation that matters for the axioms is integer equality on
  codepoints.
- **Lowering of `==`.** Integer equality on the BEAM is `=:=`
  (the strict-equality operator). It returns `true` iff both
  operands are the same term; for two integer codepoints `a` and `b`
  this is exactly value equality.
- **Soundness.** `a =:= b = true` implies `a` and `b` are the same
  integer codepoint, hence the same `Char`. Trivially.
- **Symmetry.** `=:=` is documented in OTP `erlang(3)` as a total
  commutative operator on terms; for any `a`, `b`, `a =:= b` ⟺
  `b =:= a`.

The property test exercises both properties over random codepoints
sampled from the legal range (excluding surrogates), plus explicit
boundary codepoints (`0`, ASCII boundary `0x7F`, BMP boundaries
`0xD7FF`/`0xE000`, BMP/astral boundary `0xFFFF`/`0x10000`, max
`0x10FFFF`).

## Why this isn't circular

The harness does not call `prim__eqChar`. It calls Erlang `=:=`
directly on integers. The argument is: *the operation that Idris2
lowers `prim__eqChar` to on the BEAM is `=:=` on the codepoint
integer*, so demonstrating `=:=` satisfies the properties is
sufficient. The trusted-extraction step is reading the lowering; the
property-test step is verifying the operation behaves as the lowering
claims.

For Chez, we do not run a Scheme harness — R6RS is sufficient
documentary evidence that `char=?` is a total equivalence relation. If
BoJ ever ships a backend whose Char equality is not a built-in
equivalence-checked primitive, this document gets a new section and a
matching property test.

## Edge cases considered

- **Surrogates** (`0xD800..0xDFFF`): excluded from the codepoint
  generator. These are illegal as standalone Char values per Unicode;
  if the test layer ever needs to assert behaviour on them, that is a
  bug in the system under test, not in `prim__eqChar`.
- **Normalisation** (`é` as one codepoint vs two): not in scope. The
  axiom is about codepoint equality, not grapheme-cluster equality.
  `prim__eqChar` is per-codepoint; `é` (`U+00E9`) and `e` (`U+0065`) +
  combining acute (`U+0301`) are *correctly* different chars under the
  axiom.
- **Case folding.** Not in scope; `prim__eqChar` is case-sensitive by
  spec, and the property-test `distinct codepoints are not =:=`
  invariant guards against a backend slipping case-insensitive
  collation into char equality.

## References

- Idris2 0.8.0 `src/Core/Primitives.idr` — primitive operation table.
- Idris2 0.8.0 `src/Compiler/Scheme/Chez.idr` — Chez codegen lowerings.
- R6RS §11.11 "Characters" — `char=?` specification.
- OTP `erlang(3)` — `=:=`/`=/=` specification.
- `PROOF-NEEDS.md` — axiom audit (2026-05-18).
- `src/abi/Boj/SafetyLemmas.idr` — axiom declarations (lines 53, 60).
