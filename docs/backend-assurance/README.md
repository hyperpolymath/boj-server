# Backend-Assurance Harness

External evidence for the class-(J) `believe_me` axioms in
`src/abi/Boj/SafetyLemmas.idr`. None of these documents or tests change
the in-language proof — the `believe_me` sites stay in source. The
harness shrinks the trusted base by replacing "we trust the backend"
with "we have read the backend lowering and randomly tested the
operation against the claimed property".

Per `PROOF-NEEDS.md` (Axiom Audit 2026-05-18):

> The 5 string/char-primitive axioms are **irreducible within Idris2**
> (opaque primitive types). They cannot be "proved away" in-language;
> the only reduction path is to shrink the trusted base by validating
> `prim__eqChar` / `prim__strToCharList` / `prim__strAppend` /
> `prim__strSubstr` against the chosen backend (Chez/BEAM) via an
> external trusted-extraction or property-test harness, then citing
> that evidence here.

This directory is where the trusted-extraction validation lives. The
companion property-test harness lives under
`elixir/test/backend_assurance/` (BEAM half) and is wired into CI via
`.github/workflows/backend-assurance.yml`.

## Coverage

| Primitive          | Axioms covered                       | Trusted-extraction               | Property test                                                  |
|--------------------|--------------------------------------|----------------------------------|----------------------------------------------------------------|
| `prim__eqChar`     | `charEqSound`, `charEqSym`           | `prim__eqChar.md`                | `elixir/test/backend_assurance/prim_eq_char_test.exs`          |
| `prim__strToCharList` | `unpackLength`                    | _pending_                        | _pending_                                                      |
| `prim__strAppend`  | `appendLengthSum`                    | _pending_                        | _pending_                                                      |
| `prim__strSubstr`  | `substrLengthBound`                  | _pending_                        | _pending_                                                      |

Each row is delivered as one PR per primitive. `prim__eqChar` is the
first; the other three follow the same shape.

## Constraints

- **No new `believe_me`.** External evidence only. The 5 axioms stay.
- **No in-language discharge.** Already ruled out by the 2026-05-18 audit.
- **Two backends, not one.** The trusted-extraction doc must cite both
  Chez Scheme (idris2's default codegen) and BEAM (Erlang/Elixir, where
  BoJ's REST surface runs). Property tests cover BEAM; Chez is argued
  prose-side from R6RS semantics.
- **Honest framing.** If a primitive turns out to *not* satisfy its
  axiom under some input class, document the failure and adjust the
  axiom — do not paper over it.

## Running locally

    cd elixir
    mix deps.get
    mix test --only backend_assurance

The harness has no Idris2 dependency; it validates the *backend*
operations the Idris2 axioms ultimately depend on.

## References

- `PROOF-NEEDS.md` — axiom audit and class-(J) framing.
- `src/abi/Boj/SafetyLemmas.idr` — the `believe_me` declarations.
- epic #87 Tier C — campaign tracking.
