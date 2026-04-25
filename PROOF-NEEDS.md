# PROOF-NEEDS.md — boj-server

## Current State (Updated 2026-04-25)

- **src/abi/Boj/**: 16 Idris2 ABI files
- **Dangerous patterns**: 4 `believe_me` (all documented axioms in SafetyLemmas.idr;
  `logSafeBounded` restructured to use them structurally — down from 31)
- **LOC**: ~5,400 (Elixir + Idris2)
- **ABI layer**: Comprehensive dependent-type ABI

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

### Remaining axiomatic surface (4 believe_me, all in SafetyLemmas.idr)

| Axiom | Justification |
|-------|---------------|
| `charEqSound` | Soundness of `prim__eqChar` — backend primitive correctness |
| `charEqSym` | Symmetry of `prim__eqChar` — backend primitive correctness |
| `unpackLength` | `prim__strToCharList` preserves length — backend primitive correctness |
| `appendLengthSum` | `prim__strAppend` length semantics — not reducible at type level |
| `substrLengthBound` | `prim__strSubstr` length bound — not reducible at type level |

Note: `logSafeBounded` in SafeAPIKey.idr no longer uses `believe_me` directly;
it calls the documented SafetyLemmas axioms via structural proof.

## Priority Going Forward

**LOW** — All named proof obligations closed. Future work:
- Proofs for Dap/Bsp/CodeIntel domains when those cartridges reach Ready status
- Proof that `dispatch` is surjective onto all BJ3-covered (domain, protocol) pairs
- Eliminate string-primitive axioms via a trusted extraction layer
