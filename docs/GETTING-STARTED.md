<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# BoJ Server — Getting Started

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Zig](https://ziglang.org/download/) | 0.15+ | FFI compilation |
| [V-lang](https://vlang.io/) | 0.5.0+ | Adapter compilation |
| GCC | any recent | Linking |

Optional:
- [Idris2](https://www.idris-lang.org/) — only needed to modify ABI definitions
- [just](https://just.systems/) — task runner (convenience, not required)

## Quick Start

### 1. Clone and build

```bash
git clone https://github.com/hyperpolymath/boj-server.git
cd boj-server

# Build the Zig FFI (core + all cartridges)
cd ffi/zig && zig build && cd ../..

# Build cartridge shared libraries (18 cartridges)
for cart in cartridges/*/ffi; do
  (cd "$cart" && zig build 2>/dev/null)
done

# Build the V adapter
cd adapter/v
v -cc gcc src/main.v -o boj-server
cd ../..
```

### 2. Run

```bash
cd adapter/v
export LD_LIBRARY_PATH=../../ffi/zig/zig-out/lib:../../cartridges/container-mcp/ffi/zig-out/lib:../../cartridges/feedback-mcp/ffi/zig-out/lib
./boj-server
```

The server starts on three ports:
- **REST**: http://localhost:7700
- **gRPC-compat**: http://localhost:7701
- **GraphQL**: http://localhost:7702

### 3. Verify

```bash
# Health check
curl http://localhost:7700/health
# → {"status":"ok"}

# Server status
curl http://localhost:7700/status
# → {"version":"BoJ Server v0.1.0","total_cartridges":18,...}

# Full capability matrix
curl http://localhost:7700/matrix

# Teranga menu (what's available)
curl http://localhost:7700/menu
```

### 4. Use a cartridge

```bash
# Mount a cartridge
curl -X POST http://localhost:7700/cartridges/feedback-mcp/load

# Invoke a tool
curl http://localhost:7700/cartridges/feedback-mcp/invoke \
  -X POST -H 'Content-Type: application/json' \
  -d '{"tool":"status","args":""}'
```

## Run tests

```bash
# All Zig FFI tests (307 tests)
cd ffi/zig && zig build test

# Specific module tests
zig build catalogue    # Catalogue tests only
zig build federation   # Umoja federation tests
zig build guardian     # Guardian resource-awareness tests
zig build bench        # Benchmarks
```

## Configure

All ports are configurable via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `BOJ_REST_PORT` | `7700` | REST adapter port |
| `BOJ_GRPC_PORT` | `7701` | gRPC-compat adapter port |
| `BOJ_GRAPHQL_PORT` | `7702` | GraphQL adapter port |
| `BOJ_FEDERATION_PORT` | `9999` | Umoja federation UDP/QUIC port |
| `BOJ_QUIC` | `1` | Enable QUIC transport (0 = UDP only) |
| `BOJ_NODE_ID` | `local-0` | Node identifier for federation |

## Architecture

```
Idris2 ABI (proofs) → Zig FFI (execution) → V-lang Adapter (network)
```

- **Idris2** defines types with dependent-type proofs (IsUnbreakable safety gate)
- **Zig** implements C-ABI exports (mount/unmount, federation, feedback, etc.)
- **V-lang** exposes everything as REST + gRPC + GraphQL

The capability matrix is 2D (protocol × domain) with an optional third axis
(backend/provider) for community extensions.  See `docs/EXTENSIBILITY.md`.

## Hosting a node

See `container/` for:
- `boj-community-node.container` — Podman quadlet (security-hardened)
- `seccomp-boj.json` — Restricted seccomp profile
- `seed-nodes.toml` — Seed node configuration

## Extending

See `docs/EXTENSIBILITY.md` and `docs/examples/extension.a2ml` for how to
create backend-specific cartridge extensions without modifying core code.

## Submitting feedback

BoJ dogfoods its own feedback cartridge.  After mounting `feedback-mcp`:

```bash
# Open a feedback channel
curl http://localhost:7700/cartridges/feedback-mcp/invoke \
  -X POST -H 'Content-Type: application/json' \
  -d '{"tool":"open_channel","args":"{\"channel\":\"api\"}"}'

# Submit feedback
curl http://localhost:7700/cartridges/feedback-mcp/invoke \
  -X POST -H 'Content-Type: application/json' \
  -d '{"tool":"submit","args":"{\"slot\":\"0\",\"sentiment\":\"positive\"}"}'

# View summary
curl http://localhost:7700/cartridges/feedback-mcp/invoke \
  -X POST -H 'Content-Type: application/json' \
  -d '{"tool":"summary","args":""}'
```

## MCP mode (for AI tools)

BoJ speaks MCP natively.  Run with `--mcp` to get a JSON-RPC 2.0
stdio server that AI tools like Claude Code, Cursor, etc. can consume:

```bash
# Start in MCP mode (no HTTP server, stdin/stdout only)
LD_LIBRARY_PATH=../../ffi/zig/zig-out/lib:../../cartridges/container-mcp/ffi/zig-out/lib:../../cartridges/feedback-mcp/ffi/zig-out/lib \
  ./boj-server --mcp
```

Add to `claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "boj": {
      "command": "/path/to/boj-server",
      "args": ["--mcp"],
      "env": {
        "LD_LIBRARY_PATH": "/path/to/ffi/zig/zig-out/lib:/path/to/cartridges/container-mcp/ffi/zig-out/lib:/path/to/cartridges/feedback-mcp/ffi/zig-out/lib"
      }
    }
  }
}
```

All 18 cartridges are exposed as MCP tools (e.g. `database-mcp/status`,
`feedback-mcp/submit`, etc.).

## Seam checks

BoJ includes panic-attack–style integration contract validation:

```bash
cd ffi/zig && zig build seams
```

This validates all FFI boundaries: enum encodings match Idris2 ABI,
mount safety gate rejects non-ready cartridges, hash attestation is
lossless, backend axis defaults correctly, JSON contract fields are
present, protocol range is contiguous.  A clean run produces a
"silent signature" — all 13 checks pass with nothing to report.

## Full API reference

See `docs/API-CONTRACT.md` for the complete stable API surface.
