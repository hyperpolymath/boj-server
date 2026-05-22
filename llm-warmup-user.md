# BoJ Server LLM Warmup (User Context)

## What This Is

Bundle of Joy (BoJ) Server is a cartridge-based MCP protocol gateway with
formally verified interfaces. License: MPL-2.0. Author: Jonathan D.A. Jewell.

## Architecture (30-second version)

Every cartridge (except model-router-mcp) is a triple:
1. **Idris2 ABI** — Dependent types proving correctness (zero believe_me)
2. **Zig FFI** — C-compatible .so shared library (5-symbol ADR-0006 ABI)
3. **Deno/JS adapter** — mod.js dispatched via JsWorkerPool (persistent pool)

Dispatch: `cartridge.json` with `ffi` key → `boj-invoke` CLI (dlopen .so);
without `ffi` key → `BojRest.JsWorkerPool` (Deno worker pool). Both paths
surface through the Elixir REST server on port 7700.

Three-class design: Class 1 (simple CLI), Class 2 (orchestrator), Class 3 (BEAM multiplier).

## Key Commands

```bash
just run              # Start server (REST 7700)
just test             # Run all ExUnit + FFI tests
just verify           # Full verification (typecheck + zero believe_me + build + test)
just test-smoke       # Quick smoke test
just matrix           # Show cartridge capability matrix
just doctor           # Check toolchain
```

## Ports

| Port | Protocol |
|------|----------|
| 7700 | REST (HTTP) |

## Prerequisites

Idris2 >= 0.7.0, Zig >= 0.15, Deno >= 1.40, just >= 1.25.
Optional: Rust/Cargo (for launch-scaffolder — mint/provision/config cartridges), cloudflared (for tunnels).

## Cartridges (112 total; 111 Zig FFI + 1 JS-only)

database-mcp, fleet-mcp, nesy-mcp, agent-mcp, cloud-mcp, container-mcp,
k8s-mcp, git-mcp, secrets-mcp, queues-mcp, iac-mcp, observe-mcp, ssg-mcp,
proof-mcp, lsp-mcp, dap-mcp, bsp-mcp, feedback-mcp, comms-mcp, ml-mcp,
research-mcp, ums-mcp, browser-mcp, vault-mcp, github-api-mcp, gitlab-api-mcp,
slack-mcp, discord-mcp, telegram-mcp, matrix-mcp, model-router-mcp (JS-only),
and many more.

## Key Files

| Path | Role |
|------|------|
| `src/abi/Catalogue.idr` | Cartridge registry with IsUnbreakable proof |
| `src/abi/Protocol.idr` | Protocol types (MCP, LSP, DAP, BSP...) |
| `ffi/zig/src/catalogue.zig` | Mount/unmount operations |
| `ffi/zig/src/boj_invoke_main.zig` | boj-invoke CLI (dlopen dispatch) |
| `elixir/lib/boj_rest/` | Elixir REST server (Catalog, Router, JsWorkerPool) |
| `cartridges/` | 115 cartridge directories |

## Invariants

- Zero believe_me in all Idris2 sources (currently 4 axiomatic primitives + logSafeBounded)
- %default total on all Idris2 files
- IsUnbreakable: only Ready cartridges pass the proof
- Chainguard base images, Containerfile not Dockerfile, Podman not Docker
- Cultural terms (Teranga, Umoja, Ayo) are permanent and sacred
- zig is BANNED (removed 2026-04-12)

## Seed Nodes (Umoja Federation)

Four continental seed nodes deployed on fly.io:
- `boj-seed-eu.fly.dev` — London (EU West)
- `boj-seed-de.fly.dev` — Frankfurt (EU Central)
- `boj-seed-us.fly.dev` — Virginia (US East)
- `boj-seed-ap.fly.dev` — Sydney (Asia-Pacific)

## Related Projects

PanLL (panel workbench), VeriSimDB (database), ECHIDNA (prover),
panic-attacker (security), hypatia (CI/CD scanner), launch-scaffolder (cartridge minter).
