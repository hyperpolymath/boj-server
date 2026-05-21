# Backend-Assurance: `prim__strToCharList`

Trusted-extraction validation for the class-(J) axiom over Idris2's
`prim__strToCharList` primitive:

- `unpackLength : (s : String) -> length (unpack s) = length s`
  (`src/abi/Boj/SafetyLemmas.idr:218`)

Declared `%unsafe` with `believe_me ()` in Idris2 0.8.0 because
`String` is an opaque primitive type with no constructors and no
in-language induction principle relating its primitive length to the
length of the derived `List Char`. This document argues — by
inspecting the backend lowerings that BoJ actually ships against —
that the length-preservation property holds.

The companion property test
(`elixir/test/backend_assurance/prim_str_to_char_list_test.exs`)
exercises the BEAM half of this argument over the codepoint space.

## What `prim__strToCharList` is

`prim__strToCharList : String -> List Char` is a primitive operation
declared in Idris2's `Core.Primitives`. The `unpack : String -> List
Char` definition in `Data.String` calls it directly:

    public export
    unpack : String -> List Char
    unpack = prim__strToCharList

Length is `prim__strLength` on the `String` side and the constructive
`length : List a -> Nat` on the `List Char` side. The axiom asserts
the two counts agree.

The question reduces to: does `prim__strToCharList` produce a list
whose length equals the codepoint count of the input string, on
each shipping backend?

## Chez Scheme backend (Idris2 default codegen)

In `Compiler.Scheme.Chez`, `prim__strToCharList` lowers to the R6RS
procedure `string->list`, and `prim__strLength` lowers to
`string-length`. On Chez 9.x:

- **String model.** R6RS §6.7 specifies that a Scheme string is a
  sequence of Unicode characters (codepoints).
- **`string->list` semantics.** R6RS §11.12 specifies `string->list`
  returns a newly-allocated list of the characters that make up the
  given string, in the same order.
- **Length preservation.** Combining the two: the length of
  `(string->list s)` (counting list cells) equals `(string-length
  s)`. This is part of the Scheme standard, not an implementation
  detail.

No further evidence needed beyond citing the standard.

## BEAM backend (Erlang / Elixir, where BoJ runs)

BoJ's REST surface is Elixir on the BEAM. The runtime strings are
UTF-8 encoded binaries; the analogue of `unpack` on the BEAM is
`String.to_charlist/1`.

On BEAM:

- **String model.** As with the other string primitives in this
  campaign, strings are UTF-8 binaries. The `length` referred to in
  the axiom is codepoint count, matching Idris2 semantics on Chez.
  Elixir's `String.length/1` counts grapheme clusters, so the
  BEAM-side harness measures codepoint count explicitly via
  `String.codepoints/1`.
- **`String.to_charlist/1` semantics.** Per the Elixir `String`
  module documentation, `String.to_charlist/1` decodes a UTF-8 binary
  to a list of codepoint integers. Each codepoint becomes exactly one
  list cell; UTF-8 is prefix-free, so the decode is unambiguous and
  the cell count equals the codepoint count.
- **Length preservation.** Combining the two facts:
  `length(String.to_charlist(s)) == length(String.codepoints(s))`
  for every legal UTF-8 binary `s`. The harness exercises this
  directly.

The property test exercises this over random strings sampled from the
legal codepoint range (excluding surrogates), plus explicit boundary
strings covering all four UTF-8 encoding widths (1/2/3/4 bytes) and
the empty-string corner.

## Why this isn't circular

The harness does not call `prim__strToCharList`. It calls Elixir
`String.to_charlist/1` and an explicit `String.codepoints/1` count
directly. The argument is: *BEAM charlist conversion decodes a UTF-8
binary into the same codepoint sequence that Idris `String.length`
counts*, so demonstrating those operations agree validates the
backend operation at the semantic level the axiom uses. The
trusted-extraction step is reading the lowering; the property-test
step is verifying the operation behaves as the lowering claims.

For Chez, we do not run a Scheme harness — R6RS is sufficient
documentary evidence. If BoJ ever ships a backend whose string model
is not Unicode codepoints, this document gets a new section and a
matching property test, **and the axiom may need to be restated** —
see the *Honest framing* clause in
`docs/backend-assurance/README.md`.

## Edge cases considered

- **Empty string.** `String.to_charlist("") == []`; both lengths
  are 0. Tested explicitly. A backend that allocated a sentinel
  codepoint on empty input would surface here.
- **Multi-byte codepoints.** Tested via boundary strings covering
  all four UTF-8 widths: ASCII (1 byte), Latin-1 supplement (2 bytes,
  e.g. `café`), CJK (3 bytes, e.g. `日本語`), and astral plane
  (4 bytes, e.g. `🦀`). Each width has a different number of bytes
  per codepoint, but the codepoint count (and hence the list length)
  is invariant.
- **Surrogates** (`0xD800..0xDFFF`): excluded from the codepoint
  generator. These are illegal as standalone codepoints in
  well-formed Unicode; the harness also asserts that no surrogate
  ever appears in the output of `String.to_charlist/1` on a legal
  input, as a sanity check.
- **Normalisation.** Out of scope. The axiom is about codepoint
  count, not grapheme-cluster count. `é` (`U+00E9`) yields a
  one-element charlist; `e` (`U+0065`) + combining acute (`U+0301`)
  yields a two-element charlist. Both are "correct" under the axiom.
- **Round-trip.** Not in the axiom but tested as a sanity check.
  `to_string(String.to_charlist(s)) == s` for every legal `s`. This
  guards against a backend whose `to_charlist` drops or duplicates
  codepoints in a way that happens to preserve length (e.g.
  replacing a malformed codepoint with U+FFFD on decode error).
- **Charlist element type.** The harness asserts every codepoint in
  the output is a legal integer in `0..0x10FFFF` excluding the
  surrogate range. Not the axiom but a sanity check that the
  `length` we're measuring is over real codepoints.

## References

- Idris2 0.8.0 `src/Core/Primitives.idr` — primitive operation table.
- Idris2 0.8.0 `src/Compiler/Scheme/Chez.idr` — Chez codegen lowerings
  for `prim__strToCharList` and `prim__strLength`.
- R6RS §6.7, §11.12 — Scheme string model and `string->list`
  specification.
- Elixir `String` module documentation — `String.to_charlist/1`
  and `String.codepoints/1` semantics over UTF-8 binaries.
- `PROOF-NEEDS.md` — axiom audit (2026-05-18) and class-(J) framing.
- `src/abi/Boj/SafetyLemmas.idr` — axiom declaration (line 218).
