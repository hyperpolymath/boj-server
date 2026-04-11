# PROOF-NEEDS.md — boj-server

## Current State (Updated 2026-04-11)

- **src/abi/Boj/**: 12 Idris2 ABI files (Protocol, Domain, Catalogue, Menu, Federation, Guardian, Safety, SafeHTTP, SafePromptInjection, SafeCORS, SafeAPIKey, SafeWebSocket, CartridgeDispatch)
- **Dangerous patterns**: 0
- **LOC**: ~4,200 (Elixir + Idris2)
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

## What Still Needs Proving

| # | Component | Prover | Priority |
|---|-----------|--------|----------|
| BJ2 | Auth/credential handling (full credential store isolation model) | I2 | P1 |
| BJ3 | API contract compliance (95 cartridges — protocol/domain coverage) | I2 | P2 |

Note: BJ2 partial coverage via SafeAPIKey.idr + SafeHTTP.idr. Full isolation model (per-cartridge vault partitioning) not yet written.

## Recommended Prover

**Idris2** — Already in use throughout ABI layer.

## Priority

**MEDIUM** (was HIGH) — BJ1 complete 2026-04-11. BJ2 partial; full isolation model is P1. BJ3 is P2 lower priority.
