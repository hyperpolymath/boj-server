# BoJ Server LLM Warmup (Developer Context)

## Identity

- **Name**: Bundle of Joy Server
- **License**: PMPL-1.0-or-later
- **Author**: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
- **Repo**: https://github.com/hyperpolymath/boj-server

## Architecture

### Three-Layer Cartridge Stack

Every cartridge implements a formally verified triple:

```
Idris2 ABI  →  Zig FFI  →  V-lang Adapter
(proofs)       (native)     (REST+gRPC+GraphQL)
```

### Three-Class Architecture

| Class | Focus | Technology |
|-------|-------|------------|
| 1 | Simple Track | CLI/curl, self-contained V-lang adapters |
| 2 | Orchestrator | Webhooks (HMAC-SHA256), MQTT, WebSockets |
| 3 | Multiplier | Elixir/BEAM for massive concurrency |

**Invariant**: Advanced classes NEVER damage or replace Class 1 foundation.

## Source Layout

```
src/abi/                    Idris2 ABI (formally verified)
  Catalogue.idr             Cartridge registry, IsUnbreakable proof
  Protocol.idr              Protocol types (MCP, LSP, DAP, BSP, ...)
  Domain.idr                Capability domains (Cloud, DB, K8s, ...)
  Menu.idr                  Menu generation from catalogue state
  Federation.idr            Umoja gossip protocol, node attestation
  boj.ipkg                  Package file

ffi/zig/                    Zig FFI (C-compatible)
  build.zig
  src/catalogue.zig         Catalogue mount/unmount operations
  src/loader.zig            Dynamic cartridge loader

adapter/v/                  V-lang triple adapter
  src/main.v                Unified console on port 9000
  src/class_2_orchestrator/ Advanced gateway (WS/MQTT/Webhook)

cartridges/                 70+ cartridge directories
  database-mcp/             Example cartridge
    abi/database-mcp.ipkg   Idris2 ABI
    abi/Database/Mcp.idr    Idris2 source
    ffi/build.zig           Zig FFI
    adapter/                V-lang adapter

container/                  Stapeln container ecosystem
  Containerfile             Multi-stage OCI (Chainguard base)
  compose.toml              selur-compose orchestration
  vordr.toml                Runtime monitoring

tools/cartridge-minter/     Rust CLI for minting new cartridges
  Cargo.toml

panll/src/                  PanLL panel (ReScript/TEA)

.machine_readable/          All machine-readable content
  STATE.a2ml                Project state
  META.a2ml                 Architecture decisions
  ECOSYSTEM.a2ml            Ecosystem position
  AGENTIC.a2ml              AI agent patterns
  NEUROSYM.a2ml             Neurosymbolic config
  PLAYBOOK.a2ml             Operational runbook
  servers/menu.a2ml         Teranga menu (cartridge catalogue)
  anchors/ANCHOR.a2ml       Semantic boundary
  policies/                 Governance files
  bot_directives/           Per-bot rules
  contractiles/             Policy enforcement (k9, dust, lust, must, trust)
```

## Build System

### Justfile Commands (Primary)

```bash
just build            # Build all Zig FFI layers (catalogue + cartridges)
just build-release    # Optimized build (-Doptimize=ReleaseFast)
just build-adapter    # Build V-lang adapter binary
just run              # Build + start server (REST 7700, gRPC 7701, GraphQL 7702)
just serve            # Server + Cloudflare tunnel
just test             # All FFI tests (catalogue + 17 cartridges)
just test-smoke       # Quick: typecheck core ABI + one FFI test
just verify           # typecheck + verify-no-believe-me + build + test
just typecheck        # Type-check all Idris2 ABI files
just verify-no-believe-me  # Scan for unsound constructs
just matrix           # Show cartridge capability matrix
just quality          # fmt-check + lint + test
just fmt              # Format all Zig source
just bench            # Run benchmarks
just readiness        # Component Readiness Grade tests (D/C/B)
just ci               # Full CI pipeline locally
just deps             # Check toolchain dependencies
```

### Build Flow

```
just build:
  1. cd ffi/zig && zig build          (catalogue FFI)
  2. cd cartridges/*/ffi && zig build (each cartridge FFI)

just run:
  1. just build
  2. v -cc gcc ... adapter/v/src/main.v  (V-lang adapter)
  3. exec adapter/v/boj-server
```

## Idris2 ABI Conventions

- **%default total** on all files
- **Zero believe_me** (enforced by `just verify-no-believe-me`)
- **IsUnbreakable proof**: only Ready cartridges pass
- Package files: `*.ipkg` in each abi/ directory
- Type-check: `idris2 --check --package boj boj.ipkg`

## Zig FFI Conventions

- Build via `zig build` in each ffi/ directory
- Tests: `zig build test`
- Format: `zig fmt`
- Benchmarks: `zig build bench`

## V-lang Adapter

The unified console exposes three protocol interfaces:
- REST on port 7700
- gRPC on port 7701
- GraphQL on port 7702

Build: `v -cc gcc -cflags "-L$(pwd)/ffi/zig/zig-out/lib" adapter/v/src/main.v`

## Cartridge Matrix

70+ cartridges organized in a 2D matrix (Protocol x Domain).
Each has: `abi/` (Idris2), `ffi/` (Zig), `adapter/` (V-lang).
View status: `just matrix`

Current protocol types: MCP, LSP, DAP, BSP.
Current domains: Database, Fleet, NeSy, Agent, Cloud, Container, K8s, Git,
Secrets, Queues, IaC, Observe, SSG, Proof, Comms, ML, Research, UMS,
Browser, Vault, GitHub API, GitLab API, Slack, Discord, Telegram, Matrix,
Notion, Jira, PostgreSQL, Redis, MongoDB, Neon, Turso, Fly, DigitalOcean,
Supabase, Railway, Linode, GCP, Render, Docker Hub, Hetzner, ArangoDB, Neo4j...

## Container Stack

- Base: Chainguard (cgr.dev/chainguard/wolfi-base or static)
- Runtime: Podman, never Docker
- Files: Containerfile, never Dockerfile
- Orchestration: selur-compose, never docker-compose
- Build: `just container-build`
- Run: `just container-up` / `just container-down`

## Federation (Umoja)

Distributed hosting model with gossip protocol.
Community nodes must match canonical binary hash (attestation).
See: `src/abi/Federation.idr`, `docs/FEDERATION.md`

## Cultural Terminology (Permanent, Sacred)

| Term | Origin | Usage |
|------|--------|-------|
| Teranga | Wolof (hospitality) | Menu, serving |
| Umoja | Swahili (unity) | Federation, gossip |
| Ayo | Yoruba (joy) | The BoJ philosophy |

## Critical Invariants

1. Three-Layer Stack: every cartridge = Idris2 ABI + Zig FFI + V-lang Adapter
2. Zero believe_me in all Idris2 sources
3. %default total on all Idris2 files
4. IsUnbreakable: only Ready cartridges pass the proof
5. Hash attestation for community nodes
6. PMPL-1.0-or-later on all code
7. Cultural terms are permanent and sacred
8. SCM files ONLY in .machine_readable/
9. Chainguard base images, Containerfile, Podman

## Testing

```bash
just test             # Catalogue + 17 cartridge FFI tests
just test-verbose     # With verbose output
just test-smoke       # Quick: typecheck + one FFI test
just readiness        # Readiness grade tests
just integration      # E2E integration tests
```

## Pre-commit

```bash
just assail           # panic-attacker scan
```

## Related Projects

| Project | Integration |
|---------|-------------|
| PanLL | Panel workbench, routes through BoJ |
| VeriSimDB | 8-modality database |
| ECHIDNA | Theorem prover dispatch |
| panic-attacker | Security analysis |
| hypatia | CI/CD scanner |
| gitbot-fleet | Bot orchestration |
