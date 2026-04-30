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
Idris2 ABI  →  Zig FFI  →  Deno/JS Adapter
(proofs)       (native)     (mod.js per cartridge)
```

The Elixir/BEAM REST layer dispatches invocations:
- If `cartridge.json` has an `"ffi"` key → `BojRest.Invoker` (Zig `.so` path)
- Otherwise → `BojRest.JsWorkerPool` (persistent Deno worker pool)

### Three-Class Architecture

| Class | Focus | Technology |
|-------|-------|------------|
| 1 | Simple Track | CLI/curl, self-contained cartridge invocation |
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

elixir/                     Elixir/BEAM REST server
  lib/boj_rest/
    application.ex          OTP supervisor tree
    router.ex               Plug router (health/pubkey/menu/invoke)
    catalog.ex              ETS-backed cartridge registry
    invoker.ex              Zig FFI dispatch
    js_invoker.ex           Fork-per-call Deno fallback
    js_worker.ex            GenServer wrapping a Deno port
    js_worker_pool.ex       Consistent-hash pool of JsWorkers
    node_key.ex             X25519 keypair + ChaCha20-Poly1305 decrypt
    credential_decryptor.ex Credential envelope decryption
  priv/js_pool_worker.js    Deno-side pool worker (module cache, env isolation)
  test/                     50 ExUnit tests (catalog, router, crypto, JS dispatch)
  config/                   config.exs / test.exs

cartridges/                 115 cartridge directories
  database-mcp/             Example cartridge
    abi/database-mcp.ipkg   Idris2 ABI
    abi/Database/Mcp.idr    Idris2 source
    ffi/build.zig           Zig FFI
    ffi/database_ffi.zig    FFI implementation
    mod.js                  Deno/JS tool handler (handleTool export)
    cartridge.json          Manifest (name, version, tools, auth, ffi, loopback)

container/                  Stapeln container ecosystem
  Containerfile             Multi-stage OCI (Chainguard base)
  compose.toml              selur-compose orchestration
  compose.dev.yaml          Dev compose with gateway sidecar (port 7800)
  gateway-policy.yaml       RETIRED — historical reference only; catalog mode supersedes it
  vordr.toml                Runtime monitoring

web-ecosystem/
  http-capability-gateway/  Capability gateway sidecar
    lib/http_capability_gateway/
      policy_loader.ex      load_from_boj_catalog/1 — auto-generates policy from cartridge.json

tools/                      Cartridge tooling (provisioner, configurator, harness)
  cartridge-provisioner/
  cartridge-configurator/
  panel-harness/
# Note: cartridge-minter (Node.js, banned) removed 2026-04-25. Use launch-scaffolder.

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
just run              # Start Elixir/BEAM server (REST 7700, auto-discovers 115 cartridges)
just serve            # Server + Cloudflare tunnel
just test             # Elixir ExUnit test suite (mix test)
just test-smoke       # Quick: typecheck core ABI + ExUnit smoke
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
  2. cd elixir && mix deps.get && mix run --no-halt
  (BEAM starts, Catalog scans cartridges/, JsWorkerPool spawns Deno workers)
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

## JS/Deno Adapter Conventions

Each cartridge's `mod.js` exports:
```javascript
export async function handleTool(toolId, args) {
  // returns { status: 200, data: { ... } }
}
```

The Deno worker pool (`BojRest.JsWorkerPool`) maintains N persistent Deno processes
(default 5). Requests are routed via consistent hash on `mod.js` path to maximise
module cache hits. `BojRest.JsWorker` communicates via newline-delimited JSON over
stdin/stdout.

## Cartridge Manifest (cartridge.json)

Required fields: `name`, `version`, `description`, `domain`, `tier`, `auth`, `tools`

```json
{
  "name": "example-mcp",
  "version": "1.0.0",
  "description": "...",
  "domain": "Infrastructure",
  "tier": "Ayo",
  "auth": { "method": "none" },
  "tools": [{ "id": "do_thing", "name": "Do Thing", "description": "..." }],
  "ffi": { "language": "zig", "entry": "ffi/example_ffi.zig", "so_path": "libexample_mcp.so" },
  "loopback": { "host": "127.0.0.1", "port": 5100 }
}
```

If `ffi` key is present, `BojRest.Invoker` (Zig path) is used. Otherwise `BojRest.JsWorkerPool`.

## Credential Forwarding (Option A)

Callers encrypt credentials with the server's X25519 public key:
```
GET /pubkey → base64url(X25519 public key)

Encrypt: ECDH(caller_priv, server_pub) → shared_secret
Envelope: ChaCha20-Poly1305(shared_secret, nonce, JSON_creds, AAD="boj-invoke-v1")
POST /cartridge/{name}/invoke: { "tool": "...", "args": {...}, "credential_envelope": "..." }
```

## Cartridge Matrix

115 cartridges organized in a 2D matrix (Protocol x Domain).
Each has: `abi/` (Idris2), `ffi/` (Zig), `mod.js` (Deno adapter).
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
- Gateway sidecar: `http-capability-gateway` on port 7800 → boj-rest:7700

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

1. Three-Layer Stack: every cartridge = Idris2 ABI + Zig FFI + Deno/JS `mod.js`
2. Zero believe_me in all Idris2 sources
3. %default total on all Idris2 files
4. IsUnbreakable: only Ready cartridges pass the proof
5. Hash attestation for community nodes
6. PMPL-1.0-or-later on all code
7. Cultural terms are permanent and sacred
8. A2ML files ONLY in .machine_readable/
9. Chainguard base images, Containerfile, Podman
10. V-lang is BANNED (migrated to Zig FFI + Deno/JS, 0 `.v` files as of 2026-04-12)

## Testing

```bash
just test             # Elixir ExUnit suite (50 tests: catalog, router, crypto, JS dispatch)
just test-verbose     # With verbose output
just test-smoke       # Quick: typecheck + ExUnit smoke
just readiness        # Readiness grade tests
just integration      # E2E integration tests
```

Current grade: CRG D (50 tests). Grade C requires 165+ tests.
See `TEST-NEEDS.md` for gap analysis and path to Grade C.

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
| http-capability-gateway | Gateway sidecar (port 7800); auto-generates policy from cartridge.json |
