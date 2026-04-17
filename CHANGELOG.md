<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# Changelog

All notable changes to Bundle of Joy Server are documented here.

## [0.4.0] — 2026-04-17

### Changed

- **V-lang banned estate-wide (2026-04-10)**: Adapter layer language policy updated.
  V-lang is no longer an accepted cartridge adapter language. Zig is the default
  replacement for the adapter tier (`ffi/zig/` remains; V adapter files were swept
  in commit c4674f8). Historical V-lang API interfaces have been moved to
  `developer-ecosystem/v-ecosystem/v-api-interfaces/v-<name>/` for potential
  donation to the V community — they are not HP infrastructure.
- **Cartridge manifests = Nickel** (prior closed decision `boj-cartridge-manifest-format-dd.md`):
  The authoritative cartridge manifest format is Nickel (`.ncl`). Current on-disk
  manifests are `cartridge.json`; migration to Nickel is tracked as future work
  (see open question in ADR-0002).
- **BoJ-only MCP rule** (standing estate policy): All MCP access to hyperpolymath
  services MUST route through BoJ. Standalone MCPs outside BoJ are not permitted.
  Added explicit citation in `docs/FEDERATION.md`.
- **Unified-zig-api stack alignment** (planned): BoJ will consume
  `developer-ecosystem/zig-api/` — the unified Idris2 ABI + Zig runtime + C adaptor
  + proven-backed path safety stack. `UNIFIED-ZIG-API-STACK.adoc` in
  `developer-ecosystem/` is the canonical reference. BoJ does **not yet** call
  `libzig_api` in code; alignment is tracked in ADR-0002 as future work.
  First estate consumers wired on 2026-04-17: lol-gateway (commits dbb475f/26b6b8c),
  aerie (e0b17f8), emergency-button/emergency-room (4bd070b),
  proven→zig-api path-safety wiring (6663956), gen-header CI drift check (0d6a814).
- **ADR-0002 added**: Documents the decision to align BoJ with the unified-zig-api
  stack, with explicit status of current V-lang adapter retirement and Zig migration.

## [0.3.0] — 2026-03-20

### Added
- Consolidated boj-server-mistral and boj-server-gemini into unified repo
- PanLL ReScript/TEA UI components (BojModel, BojEngine, Boj, BojModule)
- Gemini CLI extension support (gemini-extension.json, GEMINI.md)
- 9 architecture docs: Quantum Security, HSM Integration, Cartridge Marketplace,
  BoJ OS, Formal Verification, Type Safety, Zero Trust, SDP Architecture, Gossip Protocol
- Cartridge tools specification (Minter, Provisioner, Configurator, Panel Harness)
- Intentfile and Mustfile (contractile invariant declarations)
- Farm/fleet enrollment configs
- EXHIBIT-A (Ethical Use) and EXHIBIT-B (Quantum-Safe Provenance)
- Hypatia vulnerability-scanning and dependency-update rules

### Fixed
- Constant-time comparison in webhook HMAC verification (timing attack prevention)
- .mcp.json version aligned to 0.3.0
- package.json license corrected to PMPL-1.0-or-later
- SPDX headers added to all new files

### Removed
- boj-server-gemini repo (consolidated, deleted from GitHub)
- boj-server-mistral repo (consolidated, deleted locally)

## [0.2.0] — 2026-03-09

### Added
- Thread-safety hardening: `std.Thread.Mutex` on all 9 FFI modules (55 globals, ~120 exports)
- 2 thread-safety seam checks (concurrent register+query, concurrent mount+unmount)
- panic-attack assail validation (1 expected weak point in QUIC crypto, 0 critical)
- Third-axis extensibility (backend/provider dimension) with extension.a2ml template
- MCP stdio bridge (`boj-server --mcp`, JSON-RPC 2.0, all 18 cartridges as MCP tools)
- Seam checks module (15 panic-attack-style integration contract tests)
- SLA monitoring (3-tier: community/standard/premium, percentile tracking, 11 tests)
- Community cartridge submissions (Ayo tier, review state machine, 11 tests)
- Auto-SDP perimeter (zero-trust, allow-list, auto-ban, 10 tests)
- 4-continent seed node configuration (EU-West, EU-Central, US-East, AP-South)
- QUIC-first transport (X25519+ChaCha20-Poly1305, backward compatible, 10 tests)
- Multi-node federation testing (11 tests, REST API peering)
- Coprocessor dispatch (Axiom.jl-style: detect→select→dispatch→fallback, 14 tests)
- Podman secure instance (quadlet + seccomp + read-only rootfs)
- docs/API-CONTRACT.md — stable API surface
- docs/GETTING-STARTED.md — clone→build→run→test→extend
- docs/EXTENSIBILITY.md — third axis and extension mechanism

### Fixed
- V 0.5.0 http.Server auto-bind broken → pre-bind with net.listen_tcp
- Duplicate linker symbols (loader includes catalogue transitively)
- Deadlock in coprocessor select_by_name (calls selectDevice directly under mutex)

## [0.1.0] — 2026-03-08

### Added
- Core catalogue ABI (Idris2) with IsUnbreakable proof gate
- Core catalogue FFI (Zig) with C-ABI exports
- Dynamic loader with SHA-256 hash verification
- Guardian resource-aware failure tolerance (12 tests)
- V-lang triple adapter (REST 7700 + gRPC 7701 + GraphQL 7702)
- 18 cartridges: database, fleet, nesy, agent, cloud, container, k8s, git, secrets, queues, iac, observe, ssg, proof, lsp, dap, bsp, feedback
- All 18 cartridges with ABI + FFI + Adapter + .so shared library builds
- Umoja federation with QUIC+UDP gossip protocol (40 tests)
- VeriSimDB backing store integration (7 tests)
- PanLL BoJ panel (887 lines, 5 tabs)
- Containerfile (Chainguard base), compose.toml, vordr.toml
- CI pipeline (zig-test.yml)
- Configurable ports via environment variables
