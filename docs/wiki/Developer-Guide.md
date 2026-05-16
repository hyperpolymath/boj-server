<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Developer Guide

This guide is for people **developing** BoJ itself -- contributing cartridges, fixing bugs, or extending the architecture.

## Architecture Overview

Every BoJ cartridge follows a three-layer stack:

```
Idris2 ABI (formal proofs) --> Zig FFI (native execution) --> Elixir Adapter (network)
```

| Layer | Language | Purpose | Location |
|-------|----------|---------|----------|
| **ABI** | Idris2 | Dependent-type proofs, state machines, `%default total`, zero `believe_me` | `src/abi/` (core), `cartridges/*/abi/` |
| **FFI** | Zig | C-compatible native execution, zero runtime dependencies | `ffi/zig/` (core), `cartridges/*/ffi/` |
| **Adapter** | Elixir | Triple API: REST (7700) + gRPC (7701) + GraphQL (7702) | `elixir/` |

### Why these languages?

**Idris2** has dependent types that prove interface correctness at compile-time. The `IsUnbreakable` proof type mathematically guarantees that only `Ready` cartridges can be activated. This is enforced by the type checker, not by convention.

**Zig** provides native C ABI compatibility without runtime overhead. It bridges Idris2's proofs and actual system calls. Cross-compilation is built-in for varied community node hardware.

**Elixir** exposes all three API styles (REST, gRPC, GraphQL) from a single codebase on the BEAM (Plug/Cowboy). One port per protocol, one codebase to maintain.

### The Capability Matrix

```
              MCP    LSP    DAP    BSP    NeSy  Agentic  Fleet   gRPC   REST
           +------+------+------+------+------+-------+------+------+------+
Database   |  ##  |      |      |      |      |       |      |  ##  |  ##  |
Fleet      |  ##  |      |      |      |      |       |  ##  |      |  ##  |
NeSy       |  ##  |      |      |      |  ##  |       |      |      |  ##  |
Agent      |  ##  |      |      |      |      |  ##   |      |  ##  |  ##  |
Cloud      |  ##  |      |      |      |      |       |      |  ##  |  ##  |
...        +------+------+------+------+------+-------+------+------+------+
```

- **Rows** = capability domains (what the server does)
- **Columns** = protocol types (how you talk to it)
- **Cells** = cartridges (formally verified, swappable modules)
- **Third axis** (optional) = backend/provider for community extensions

## Building from Source

### Prerequisites

| Tool | Version | Required? |
|------|---------|-----------|
| [Zig](https://ziglang.org/) | 0.15.2+ | Yes |
| [Elixir](https://elixir-lang.org/) | 1.15+ | Yes (for adapter) |
| GCC | any recent | Yes (linking) |
| [Idris2](https://www.idris-lang.org/) | 0.8.0 | Only to modify ABI |
| [just](https://just.systems/) | 1.40+ | Optional (convenience) |

Or use the declarative environment:

```bash
guix shell -D -f guix.scm    # Guix (primary)
nix develop                    # Nix (fallback)
```

### Build steps

```bash
git clone https://github.com/hyperpolymath/boj-server.git
cd boj-server

# Build core Zig FFI
cd ffi/zig && zig build && cd ../..

# Build all 18 cartridge shared libraries
for cart in cartridges/*/ffi; do
  (cd "$cart" && zig build 2>/dev/null)
done

# Fetch Elixir backend deps (the REST/gRPC/GraphQL surface)
cd elixir
mix deps.get && mix compile
cd ..
```

With `just`:

```bash
just deps       # Verify toolchain
just build      # Build all Zig FFI layers
just typecheck  # Type-check all Idris2 ABI files
just verify     # Full verification (zero believe_me + typecheck + tests)
```

## Adding a New Cartridge

### 1. Choose your matrix cell

Pick a capability domain and protocol(s):

- **Domains**: Cloud, Container, Database, K8s, Git, Secrets, Queues, IaC, Observe, SSG, Proof, Fleet, NeSy, Agent, LSP, DAP, BSP, Feedback
- **Protocols**: MCP, LSP, DAP, BSP, NeSy, Agentic, Fleet, gRPC, REST

### 2. Create the directory structure

```
cartridges/your-cartridge-name/
  abi/           # Idris2 source
  ffi/           # Zig source (with build.zig)
```

The network surface (REST/gRPC/GraphQL) is served centrally by the
Elixir backend in `elixir/`; cartridges expose only the ABI + FFI layers.

### 3. Write the Idris2 ABI

Requirements:
- Use `%default total` in all files
- Zero `believe_me`, `assert_total`, or `assert_smaller`
- Define types and operations with C-ABI encoding/decoding functions (Int <-> your types)

### 4. Write the Zig FFI

Requirements:
- Match the Idris2 ABI's integer encodings exactly
- Use `export fn` for all C-callable functions
- Include tests
- Zero runtime dependencies
- Wrap all mutable globals with `std.Thread.Mutex` (see Thread-Safety below)

### 5. Wire the cartridge into the Elixir adapter

The network surface (REST/gRPC/GraphQL) is served centrally by the
Elixir backend in `elixir/` — there is no per-cartridge adapter to write.
Ensure your cartridge:
- Is reachable via the declared protocols through the Elixir backend
- Handles the order-ticket protocol
- Returns proper status responses

### 6. Register in the menu

Add your cartridge to `.machine_readable/servers/menu.a2ml` under the **Ayo** section (community tier). Set status to `Development` initially.

### 7. Pass the IsUnbreakable proof

Submit a PR. CI verifies:
- Zero `believe_me` in your ABI
- `%default total` in all Idris2 files
- Zig builds clean
- All tests pass
- SPDX headers present (`PMPL-1.0-or-later`)

When merged, your cartridge status changes to `Ready` and appears in the Ayo section of the Teranga menu.

## Creating Extensions (Third Axis)

The third axis allows community extensions to specialise a cartridge for a specific backend/provider **without modifying core code**.

### Write an extension descriptor

Create a `.a2ml` file:

```toml
[extension]
name = "database-mcp-pg"
domain = "database"
backend = "postgresql"
tier = "ayo"
protocols = ["mcp", "rest"]

[metadata]
author = "Your Name <you@example.com>"
description = "PostgreSQL-native database cartridge"
```

### Build a shared library

Export the BoJ cartridge invoke contract:

```c
int boj_ext_invoke(const char* tool, const char* params_json,
                   char* result_buf, size_t result_len);
```

### Register via REST

```bash
curl -X POST http://localhost:7700/community/submit \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "database-mcp-pg",
    "author": "Your Name <you@example.com>",
    "description": "PostgreSQL-native database cartridge",
    "hash": "a1b2c3...64-char-sha256"
  }'
```

See [`docs/EXTENSIBILITY.md`](../EXTENSIBILITY.md) for the full guide.

## Running Tests

```bash
cd ffi/zig

# All tests (307+)
zig build test

# Specific modules
zig build catalogue    # Catalogue tests
zig build federation   # Umoja federation tests (40 tests)
zig build guardian     # Guardian resource-awareness (12 tests)
zig build bench        # Benchmarks

# Seam checks (panic-attack-style integration contract validation)
zig build seams
```

### What seam checks validate

Seam checks are integration contract tests that verify FFI boundaries:
- Enum encodings match Idris2 ABI definitions
- Mount safety gate rejects non-ready cartridges
- Hash attestation is lossless
- Backend axis defaults to `"universal"`
- JSON contract fields are present
- Protocol range is contiguous

A clean run produces a **silent signature** -- all 13 checks pass with nothing to report.

### Test organisation

| Suite | Count | What it tests |
|-------|-------|---------------|
| Core FFI | 178 | Catalogue, loader, federation, guardian, readiness, VeriSimDB, e2e, coprocessor, SLA, community, SDP, seams |
| Cartridge FFI | 118 | Per-cartridge Zig tests |
| Multi-node federation | 11 | REST API peer management, gossip |
| Total | 307+ | |

## Thread-Safety Patterns

All 9 FFI modules in BoJ use `std.Thread.Mutex` to protect mutable global state. This covers 55 globals and 120 exports.

### Pattern

```zig
var mutex = std.Thread.Mutex{};
var global_state: StateType = .{};

pub export fn boj_some_operation() callconv(.C) c_int {
    mutex.lock();
    defer mutex.unlock();
    // ... access global_state safely ...
}
```

### Rules

1. **Every mutable global** must have a corresponding mutex
2. **Every exported function** that touches mutable state must lock before access
3. **Use `defer mutex.unlock()`** to guarantee unlock on all code paths
4. **Never hold two mutexes** at the same time (prevents deadlocks)
5. **Keep critical sections short** -- do computation outside the lock when possible

## Project Structure

```
src/abi/              # Idris2 ABI -- formal proofs
  Catalogue.idr       #   Cartridge registry, IsUnbreakable proof
  Protocol.idr        #   Protocol type definitions
  Domain.idr          #   Capability domain definitions
  Menu.idr            #   Teranga menu structure
  Federation.idr      #   Umoja federation types
  Guardian.idr        #   Resource-aware failure tolerance

ffi/zig/              # Zig FFI -- native execution
  src/catalogue.zig   #   Mount/unmount, cartridge ops
  src/loader.zig      #   Dynamic cartridge loading
  src/federation.zig  #   Gossip protocol, QUIC transport
  src/verisimdb.zig   #   VeriSimDB backing store
  src/guardian.zig     #   Resource-aware failure tolerance
  src/readiness.zig   #   Readiness probes
  src/coprocessor.zig #   Hardware accelerator dispatch
  src/bench.zig       #   Benchmarks
  src/e2e_order.zig   #   End-to-end order-ticket tests

cartridges/           # 18 cartridge directories
  database-mcp/       #   Each has abi/ + ffi/
  container-mcp/
  ...

elixir/               # REST + gRPC + GraphQL server (Plug/Cowboy)

container/            # Deployment
  Containerfile       #   Chainguard base image
  compose.toml        #   selur-compose orchestration
  vordr.toml          #   Runtime monitoring config
  seccomp-boj.json    #   Restricted seccomp profile
  seed-nodes.toml     #   Federation seed nodes
  boj-community-node.container  # Podman quadlet unit

generated/abi/        # Auto-generated C headers from Idris2
.machine_readable/    # State files, menu, policies
docs/                 # Architecture, API contract, guides
```

## Contributing

See [`CONTRIBUTING.md`](../../CONTRIBUTING.md) for the full contribution guide, including commit conventions, PR requirements, and the gitbot-fleet review process.

All contributions must include SPDX headers (`PMPL-1.0-or-later`) and pass the CI pipeline (`zig-test.yml`).
