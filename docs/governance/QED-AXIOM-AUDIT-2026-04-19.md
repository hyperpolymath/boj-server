# BoJ QED Axiomatic Audit — 2026-04-19

Scope: documented-axiomatic `believe_me` sites in:

- `src/abi/Boj/SafetyLemmas.idr`
- `src/abi/Boj/SafeAPIKey.idr`

Method:

1. Enumerate all `believe_me` sites in the two modules.
2. Verify each site has an explicit nearby rationale comment.
3. Check rationale still matches implementation shape and dependency surface.

## Findings

| Site | Declared rationale | Audit verdict |
|---|---|---|
| `SafetyLemmas.idr:52` (`charEqSound`) | Soundness of backend primitive `prim__eqChar` | Still accurate. Proof depends on backend correctness, not local logic. |
| `SafetyLemmas.idr:58` (`charEqSym`) | Symmetry of backend primitive `prim__eqChar` | Still accurate. Symmetry is delegated to primitive behavior. |
| `SafetyLemmas.idr:208` (`unpackLength`) | `prim__strToCharList` preserves string length | Still accurate. Length preservation is primitive-level; no local contradiction found. |
| `SafeAPIKey.idr:152` (`logSafeBounded`) | `substr`/append length arithmetic not reducible at Idris type level | Still accurate. Runtime construction (`"***"` or `4+3+4`) matches stated bound logic. |

## Outcome

- 4/4 sites are still correctly documented as axiomatic.
- No stale rationale text detected.
- No immediate code change required for correctness; keep these under
  "documented axiomatic" debt rather than "silent assumption" debt.
