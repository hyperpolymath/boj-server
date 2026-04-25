# BoJ Server LLM Warmup (User Context)

## What This Is

Bundle of Joy (BoJ) Server is a cartridge-based MCP protocol gateway with
formally verified interfaces. License: PMPL-1.0-or-later. Author: Jonathan D.A. Jewell.

## Architecture (30-second version)

Every cartridge is a triple:
1. **Idris2 ABI** -- Dependent types proving correctness (zero believe_me)
2. **Zig FFI** -- C-compatible native execution
3. **V-lang Adapter** -- REST + gRPC + GraphQL

Three-class design: Class 1 (simple CLI), Class 2 (orchestrator), Class 3 (BEAM multiplier).

## Key Commands

```bash
just run              # Start server (REST 7700, gRPC 7701, GraphQL 7702)
just test             # Run all FFI tests (18 suites)
just verify           # Full verification (typecheck + zero believe_me + build + test)
just test-smoke       # Quick smoke test
just matrix           # Show cartridge capability matrix
just doctor           # Check toolchain
```

## Ports

| Port | Protocol |
|------|----------|
| 7700 | REST (HTTP) |
| 7701 | gRPC |
| 7702 | GraphQL |

## Prerequisites

Idris2 >= 0.7.0, Zig >= 0.13, V (vlang) >= 0.4.4, just >= 1.25.
Optional: Cargo (for launch-scaffolder — mint/provision/config cartridges), cloudflared (for tunnels).

## Cartridges (70+)

database-mcp, fleet-mcp, nesy-mcp, agent-mcp, cloud-mcp, container-mcp,
k8s-mcp, git-mcp, secrets-mcp, queues-mcp, iac-mcp, observe-mcp, ssg-mcp,
proof-mcp, lsp-mcp, dap-mcp, bsp-mcp, feedback-mcp, comms-mcp, ml-mcp,
research-mcp, ums-mcp, browser-mcp, vault-mcp, github-api-mcp, gitlab-api-mcp,
slack-mcp, discord-mcp, telegram-mcp, matrix-mcp, and many more.

## Key Files

| Path | Role |
|------|------|
| src/abi/Catalogue.idr | Cartridge registry with IsUnbreakable proof |
| src/abi/Protocol.idr | Protocol types (MCP, LSP, DAP, BSP...) |
| ffi/zig/src/catalogue.zig | Mount/unmount operations |
| adapter/v/src/main.v | Unified console (REST+gRPC+GraphQL) |
| cartridges/ | 70+ cartridge directories |

## Invariants

- Zero believe_me in all Idris2 sources
- %default total on all Idris2 files
- IsUnbreakable: only Ready cartridges pass the proof
- Chainguard base images, Containerfile not Dockerfile, Podman not Docker
- Cultural terms (Teranga, Umoja, Ayo) are permanent and sacred

## Related Projects

PanLL (panel workbench), VeriSimDB (database), ECHIDNA (prover),
panic-attacker (security), hypatia (CI/CD scanner).
