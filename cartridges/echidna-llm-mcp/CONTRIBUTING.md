<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->

# Contributing to `echidna-llm-mcp`

This cartridge is part of [`boj-server`](../../). Contribution flow follows
the parent repo's [`CONTRIBUTING.md`](../../CONTRIBUTING.md).

## Cartridge-specific guidance

- **Tool surface lives in `mod.js`** (Deno transport) and `ffi/echidna_llm_ffi.zig`
  (Zig native FFI). Adding a new tool requires updating both, plus
  [`docs/CALL-PROTOCOL.adoc`](docs/CALL-PROTOCOL.adoc).
- **All 105 echidna prover backends** are addressable by slug per
  `docs/CALL-PROTOCOL.adoc`. New provers added upstream in echidna show
  up via the slug catalogue, not via cartridge changes.
- **Build**:
  ```bash
  # Zig adapter (optional native path)
  cd adapter && zig build
  # FFI tests
  cd ffi && zig build test
  ```
- **No npm / Bun / pnpm**: Deno only (per estate language policy).
- **License**: PMPL-1.0-or-later for new files (with MPL-2.0 as automatic
  legal fallback). Keep SPDX headers on every source file.

## What goes in this cartridge vs upstream

- **In here**: protocol shim — JSON-RPC tool dispatch, slug → echidna REST
  routing, response transformation.
- **Upstream in echidna**: the actual prover dispatch, trust pipeline,
  proof exchange. Don't duplicate logic that belongs in echidna.

## What goes in `boj-server` parent vs this cartridge

- **In parent**: BoJ loader, cartridge registration, security policy,
  shared FFI primitives in `ffi/zig/`.
- **In here**: echidna-specific transport + tool surface only.

For everything else, defer to the parent.
