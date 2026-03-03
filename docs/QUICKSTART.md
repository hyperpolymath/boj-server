<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# Quickstart

Get up and running in 60 seconds.

## Prerequisites

- [Git](https://git-scm.com/) 2.40+
- [Idris2](https://www.idris-lang.org/) 0.8.0 (ABI layer)
- [Zig](https://ziglang.org/) 0.15.2 (FFI layer)
- [just](https://github.com/casey/just) 1.40+ (command runner)

Or use the development environment:

```bash
guix shell -D -f guix.scm    # Guix (primary)
nix develop                    # Nix (fallback)
```

## Clone and Setup

```bash
git clone https://github.com/hyperpolymath/boj-server.git
cd boj-server
just deps       # Verify toolchain
```

## Build and Test

```bash
just build      # Build all Zig FFI layers
just test       # Run all FFI test suites
just typecheck  # Type-check all Idris2 ABI files
just verify     # Full verification (zero believe_me + typecheck + tests)
```

## Project Structure

```
src/abi/           # Idris2 ABI — formal proofs (Catalogue, Protocol, Domain, Menu, Federation)
ffi/zig/           # Zig FFI — catalogue operations (mount/unmount)
generated/abi/     # C headers generated from Idris2
cartridges/        # Matrix cells — one dir per (Protocol x Domain) pair
  database-mcp/    # MCP x Database (abi/ + ffi/)
  fleet-mcp/       # MCP x Fleet (abi/ + ffi/)
  nesy-mcp/        # MCP x NeSy (abi/ + ffi/)
  agent-mcp/       # MCP x Agent (abi/ + ffi/)
adapter/v/         # V-lang triple adapter (REST+gRPC+GraphQL) — Phase 3
container/         # Stapeln container ecosystem
docs/              # Architecture, federation, developer guides
.machine_readable/ # State files, menu, policies, contractiles
```

## What Next?

- Read [ARCHITECTURE.md](ARCHITECTURE.md) for the 2D matrix design
- Read [DEVELOPERS.md](DEVELOPERS.md) to contribute a cartridge
- Run `just --list` to see all available commands
- Read [CONTRIBUTING.md](../CONTRIBUTING.md) for the full contribution guide

## Troubleshooting

If `just deps` fails, ensure your toolchain versions match `.tool-versions`:

```
idris2 0.8.0
zig    0.15.2
just   1.40.0
```

Open a [Discussion](https://github.com/hyperpolymath/boj-server/discussions)
if you get stuck.
