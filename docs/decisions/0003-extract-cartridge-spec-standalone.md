<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# 3. Extract Cartridge Specification as Standalone Normative Document

Date: 2026-04-17

## Status

Accepted

## Context

Prior to 2026-04-17, the normative definition of a BoJ cartridge was distributed
across three locations with no single authoritative source:

1. **`src/abi/Boj/Catalogue.idr`** — the formal 2D capability matrix, cartridge
   record type, `IsUnbreakable` predicate, `CartridgeStatus` lifecycle, `MenuTier`
   tiers, hash attestation requirement, and catalogue query functions. Authoritative
   for the machine, but not human-readable as an overview document.

2. **`docs/papers/boj-architecture-paper.md §6`** — the HAT (Hardware Attached on
   Top) third dimension was described here in prose, as part of a broader architecture
   narrative. Not normative on its own; embedded inside a longer paper.

3. **Implicit in `cartridge-minter/` expectations** — the cartridge-tools suite
   (`mint`, `provision`, `config`, `harness`) encoded assumptions about cartridge
   structure without a single document to reference back to. This made it hard to
   tell what was spec vs. implementation detail.

There was no standalone document covering the full cartridge concept: the 2D matrix,
the HAT third dimension, the Nickel manifest shape, the three-axis surface
ephemerality model, transaction-based ephemerality, transport preference ordering,
security grades, transport provenance, and the reference implementation pattern.

## Decision

Extract the cartridge specification into `docs/specification/cartridges/README.md`
as the **normative prose specification** for BoJ cartridges. This document:

- Covers the ProtocolType axis (9 protocols), the CapabilityDomain axis (18 domains),
  and the 2D sparse capability matrix.
- Defines the HAT third dimension with the four bridge types (CLI wrapper, JSON-RPC
  stdio, HTTP API, Library FFI) and the circuit-breaker isolation model.
- Specifies the Nickel cartridge manifest schema with required fields, `TransportEntry`
  shape, and a worked example.
- Defines the three-axis surface ephemerality model
  (`possible_transports` / `preferred_transports` / `active_transports`) and
  transaction-based ephemerality.
- Specifies transport preference ordering, the four-tier security grade ladder
  (A/B/C/D), and transport provenance conventions.
- Documents the reference implementation pattern (Idris2 → Zig → Rust Tauri command
  layer → bridge directory) using the IDApTIK UMS cartridge as the canonical example.

The Idris2 source files (`src/abi/Boj/Catalogue.idr`, `src/abi/Boj/Protocol.idr`,
`src/abi/Boj/Domain.idr`) remain the **machine-authoritative** definition. If the
prose spec and the Idris2 source ever disagree, the Idris2 source wins.

## Consequences

### Positive

- Single source of truth for all cartridge-related questions. Onboarding a new
  cartridge author now has a clear starting point.
- The cartridge-tools suite (`docs/specification/cartridge-tools/README.md`) can
  reference the cartridge spec as its upstream normative document, without embedding
  its own copy of cartridge definitions.
- Sets the normative shape for the planned Nickel manifest migration (ADR 0002 open
  question #2). Cartridge authors can start writing `.ncl` manifests against a
  documented schema even before migration tooling exists.
- The `[CARTRIDGE_SPEC_REF]` section of the BoJ Trustfile now has a concrete
  normative target to point at.

### Negative

- `docs/papers/boj-architecture-paper.md §6` (HAT description) is now slightly
  redundant. It has been annotated with a forward-reference to
  `docs/specification/cartridges/README.md` as the normative source; the paper
  retains its narrative value for new readers but is no longer the primary HAT
  definition.
- The cartridge spec must be kept in sync with `src/abi/Boj/Catalogue.idr` as the
  Idris2 code evolves. Recommended enforcement: ECHIDNA diff-tooling or a CI step
  that cross-checks enum cardinalities between the Idris2 source and the prose spec.

### Neutral

- Existing `cartridge.json` files are unaffected. The spec records both the Nickel
  (new) and JSON (legacy) manifest formats. Migration schedule unchanged (see ADR 0002
  open question #2).
- The `IsUnbreakable` proof and its circuit-breaker semantics are described in the
  spec but remain enforced by the Zig FFI layer; no code change is implied.

## Related

- ADR 0001 (RSR adoption) — establishes `docs/decisions/` as the home for ADRs.
- ADR 0002 (unified-zig-api alignment) — Nickel manifest migration open question.
- Commit `b1b40f7` — extraction of the cartridge spec into this document.
- Commit `ceae54c` — BoJ Trustfile speciation with `[CARTRIDGE_SPEC_REF]` section.
