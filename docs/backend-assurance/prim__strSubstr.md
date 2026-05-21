# Backend-Assurance: `prim__strSubstr`

Trusted-extraction validation for the class-(J) axiom over Idris2's
`prim__strSubstr` primitive:

- `substrLengthBound : (s : String) -> (start, len : Nat) ->
  LTE (length (substr start len s)) len`
  (`src/abi/Boj/SafetyLemmas.idr:233`)

Declared `%unsafe` with `believe_me ()` in Idris2 0.8.0 because
`String` is an opaque primitive type. This document argues — by
inspecting the backend lowerings that BoJ actually ships against —
that the length-bound property holds.

The companion property test
(`elixir/test/backend_assurance/prim_str_substr_test.exs`) exercises
the BEAM half of this argument over the codepoint space.

## What `prim__strSubstr` is

`prim__strSubstr : Int -> Int -> String -> String` is a primitive
arithmetic operation declared in Idris2's `Core.Primitives`. The
`substr : Nat -> Nat -> String -> String` definition in
`Data.String` wraps the primitive after casting the `Nat` arguments
to `Int`. Length is `prim__strLength` (`length : String -> Nat`).

The question reduces to: does `prim__strSubstr(start, len, s)`
produce a string whose `prim__strLength` is at most `len`, for every
`(start, len, s)`?

A weaker phrasing — that the result has length **equal to** `len`
when `start + len ≤ length(s)`, and at most `len` otherwise — is the
operational specification. The axiom only claims the upper bound,
which is the safety-relevant half (preventing buffer-length under-
estimation in downstream proofs).

## Chez Scheme backend (Idris2 default codegen)

In `Compiler.Scheme.Chez`, `prim__strSubstr` lowers to a Scheme
expression equivalent to `(substring s start (min (+ start len)
(string-length s)))`. The implementation clamps the end index to the
string's actual length so the call is total even when
`start + len > length(s)`.

On Chez 9.x:

- **`substring` semantics.** R6RS §11.12 specifies `substring`
  returns a newly-allocated string containing the characters of the
  argument from `start` (inclusive) to `end` (exclusive). When
  `start = end`, the result is the empty string.
- **Length of the result.** The number of characters in
  `(substring s start end)` is `end - start`. With the clamp
  `end = min(start + len, string-length s)`:
  - If `start + len ≤ string-length s`: result length is exactly
    `len`. ✓ `LTE len len`.
  - If `start ≥ string-length s`: clamp forces `end = start`, result
    is empty. ✓ `LTE 0 len`.
  - Otherwise: result length is `string-length s - start`, which by
    the clamp is `< len`. ✓.

The bound `result length ≤ len` holds in all cases. This is part of
the R6RS guarantee for `substring` combined with the codegen's clamp.

## BEAM backend (Erlang / Elixir, where BoJ runs)

BoJ's REST surface is Elixir on the BEAM. The runtime strings are
UTF-8 encoded binaries; substring extraction goes through Elixir's
`String.slice/3`.

On BEAM:

- **String model.** As with `prim__strAppend`, strings are UTF-8
  binaries and `String.length/1` returns codepoint count. The
  `length` referred to in the axiom is codepoint count, matching
  Idris2 semantics on Chez.
- **`String.slice/3` semantics.** Per the Elixir `String` module
  documentation, `String.slice(s, start, len)` returns at most `len`
  codepoints from `s`, starting at codepoint offset `start`. The
  function clamps to the string's actual codepoint length: when
  `start ≥ length(s)`, the result is `""`; when `start + len >
  length(s)`, the result is the suffix from `start` to the end (which
  is strictly shorter than `len`).
- **Length bound.** Combining the two facts:
  `String.length(String.slice(s, start, len)) ≤ len` for all
  `(start, len, s)`. The clamp can only *shorten* the result;
  it never extends past `len`.

The property test exercises this over random `(start, len, s)` tuples
plus explicit boundary cases: `len = 0`, `start ≥ length(s)`,
`start = 0` and `len = length(s)`, and multi-byte codepoint strings
where codepoint count differs from byte count.

## Why this isn't circular

The harness does not call `prim__strSubstr`. It calls Elixir
`String.slice/3` and `String.length/1` directly. The argument is:
*the operation that Idris2 lowers `prim__strSubstr` to on the BEAM
is `String.slice/3` on a UTF-8 binary*, so demonstrating
`String.slice/3` satisfies the property is sufficient. The
trusted-extraction step is reading the lowering; the property-test
step is verifying the operation behaves as the lowering claims.

For Chez, we do not run a Scheme harness — the R6RS `substring`
semantics combined with the codegen's clamp are sufficient
documentary evidence.

## Edge cases considered

- **`len = 0`.** The tight corner of the bound: result must be the
  empty string. R6RS `substring` with `end = start` returns `""`;
  BEAM `String.slice/3` with `len = 0` returns `""`. Both satisfy
  `LTE 0 0`.
- **`start ≥ length(s)`** (start past end). Both backends clamp to
  the empty string; the bound `LTE 0 len` is trivial.
- **`start + len > length(s)`** (overflow tail). Both backends clamp
  the result to the suffix from `start` to the actual end. The
  resulting length is `length(s) - start`, which is strictly less
  than `len` (since `length(s) < start + len`).
- **`start = 0`, `len = length(s)`** (whole-string slice). The
  result is `s` itself; the bound is tight (`LTE length(s)
  length(s)`).
- **Multi-byte codepoints.** Tested via boundary strings covering
  ASCII, Latin-1 supplement, CJK, and astral plane. `String.slice/3`
  counts codepoints, not bytes, so a slice of length `len` from an
  emoji-heavy string spans `4 * len` bytes but `len` codepoints.
- **Surrogates** (`0xD800..0xDFFF`): excluded from the codepoint
  generator. Same rationale as `prim__strAppend`.
- **Negative `start` / `len`.** Idris2's `substr` takes `Nat`, so
  the values are non-negative by typing. The BEAM-side test
  generators sample from `0..96` only; the harness does not assert
  behaviour on negative inputs because the type system rules them out
  upstream.

## References

- Idris2 0.8.0 `src/Core/Primitives.idr` — primitive operation table.
- Idris2 0.8.0 `src/Compiler/Scheme/Chez.idr` — Chez codegen for
  `prim__strSubstr` (clamp + R6RS `substring`).
- R6RS §11.12 — `substring` specification.
- Elixir `String` module documentation — `String.slice/3` clamp
  semantics.
- `PROOF-NEEDS.md` — axiom audit (2026-05-18) and class-(J) framing.
- `src/abi/Boj/SafetyLemmas.idr` — axiom declaration (line 233).
