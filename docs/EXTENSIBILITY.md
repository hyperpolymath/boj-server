<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
# BoJ Server — Extensibility Guide

## Purpose

This document describes how external developers can extend the BoJ catalogue
**without modifying core infrastructure**.  The extension mechanism exists to
make the design readily expansible; it is not a scope increase for the
project itself.

## The Capability Matrix

BoJ organises server capabilities as a sparse matrix:

```
               Protocol (column)
             ┌─────┬─────┬─────┬─────┬─────┬─────┐
  Domain     │ MCP │ LSP │ DAP │ BSP │ gRPC│ REST│
  (row)      ├─────┼─────┼─────┼─────┼─────┼─────┤
  Database   │  ██ │     │     │     │  ██ │  ██ │
  Container  │  ██ │     │     │     │  ██ │  ██ │
  ...        │     │     │     │     │     │     │
             └─────┴─────┴─────┴─────┴─────┴─────┘
```

**Two primary dimensions:**
- **Rows** = capability domains (database, container, secrets, k8s, ...)
- **Columns** = protocol types (MCP, LSP, DAP, BSP, gRPC, REST, ...)

**One optional third dimension:**
- **Depth** = backend/provider (universal, postgresql, podman, aws, ...)

## The Third Axis: Backend

Every cartridge has a `backend` field that defaults to `"universal"`.
Core BoJ cartridges are all universal — they define the capability
abstraction without committing to a specific provider.

Community extensions can **specialise** this axis.  For example:

| Cartridge | Domain | Backend | What it does |
|-----------|--------|---------|-------------|
| database-mcp | Database | universal | Generic database operations |
| database-mcp-pg | Database | postgresql | PostgreSQL-native operations |
| database-mcp-sqlite | Database | sqlite | SQLite-native operations |
| container-mcp | Container | universal | Generic container operations |
| container-mcp-podman | Container | podman | Podman-specific tooling |

This means the matrix is actually:

```
  (Domain, Protocol, Backend) → Cartridge
```

But the third axis is opt-in.  If you don't set `backend`, it is `"universal"`
and the cartridge behaves exactly as the existing 2D model.

## Creating an Extension

To extend BoJ with a backend-specific cartridge:

### 1. Write an Extension Descriptor

> **Manifest format note (2026-04-17):** The closed decision
> `boj-cartridge-manifest-format-dd.md` establishes **Nickel** (`.ncl`) as the
> authoritative cartridge manifest format. Current on-disk manifests are
> `cartridge.json`. Migration from JSON to Nickel is tracked as future work.
> Until migration is complete, both formats coexist; the JSON schema at
> `https://boj.dev/schemas/cartridge/v1.json` remains the operative validator.

Create a manifest file describing your extension (currently `cartridge.json`; Nickel
`.ncl` is the planned authoritative format):

```toml
# my-extension.cartridge.json — Extension descriptor for BoJ catalogue
# (Future: migrate to my-extension.ncl in Nickel format)
[extension]
name = "database-mcp-pg"
version = "0.1.0"
domain = "database"          # Must match a CapabilityDomain
backend = "postgresql"       # Your specialisation
tier = "ayo"                 # Community extensions are always Ayo tier
protocols = ["mcp", "rest"]  # Which protocol columns this fills

[metadata]
author = "Your Name <you@example.com>"
description = "PostgreSQL-native database cartridge for BoJ"
homepage = "https://github.com/you/database-mcp-pg"
hash = ""                    # SHA-256 of the .so — filled at build time

[capabilities]
tools = [
  "pg_query",
  "pg_schema",
  "pg_migrate",
]
```

### 2. Build a Shared Library

Your extension compiles to a `.so` (or `.dylib` on macOS) that exports
C-ABI functions matching the BoJ cartridge invoke contract:

```c
// Required export:
int boj_ext_invoke(const char* tool, const char* params_json,
                   char* result_buf, size_t result_len);
```

### 3. Register via the REST API

Submit your extension to a running BoJ node:

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

The node operator reviews the submission via the Ayo tier state machine
(submitted → under_review → approved/rejected).

### 4. Register Programmatically (FFI)

If you are building against the BoJ static library:

```c
#include "boj_catalogue.h"

boj_catalogue_register("database-mcp-pg", 15, "0.1.0", 5,
                        1,  /* ready */
                        2,  /* ayo tier */
                        3); /* database domain */
boj_catalogue_set_backend("postgresql", 10);
boj_catalogue_add_protocol(1);  /* MCP */
boj_catalogue_add_protocol(9);  /* REST */
```

## What This Is Not

This extensibility mechanism is **not**:

- A plugin system with dynamic loading (extensions are static .so files)
- A marketplace or registry (BoJ does not host or distribute extensions)
- A scope increase (core BoJ remains the 18 universal cartridges)
- A commitment to support arbitrary backends

It is simply a **designed seam** in the type system that allows the
community to specialise the catalogue along a natural axis without
forking or modifying core infrastructure.  Someone can look at this
and say: "great, this is expansible" — and try out their own ideas
on the backend dimension.

## Querying Extensions

The Teranga menu JSON includes the `backend` field:

```json
{
  "menu": "teranga",
  "cartridges": [
    {
      "name": "database-mcp",
      "backend": "universal",
      "tier": "teranga",
      "protocols": ["mcp", "rest"]
    },
    {
      "name": "database-mcp-pg",
      "backend": "postgresql",
      "tier": "ayo",
      "protocols": ["mcp", "rest"]
    }
  ]
}
```

The REST API also supports backend queries:

```bash
# List all database cartridges (any backend)
curl http://localhost:7700/cartridges?domain=database

# List only PostgreSQL-specialised cartridges
curl http://localhost:7700/cartridges?domain=database&backend=postgresql
```

## Idris2 ABI

The `Cartridge` record in `Boj.Catalogue` includes:

```idris
record Cartridge where
  constructor MkCartridge
  name       : String
  version    : String
  status     : CartridgeStatus
  tier       : MenuTier
  domain     : CapabilityDomain
  protocols  : List ProtocolType
  binaryHash : String
  backend    : String    -- "universal" | provider-specific label
```

Query functions:

```idris
isBackendSpecific : Cartridge -> Bool
byBackend : String -> List Cartridge -> List Cartridge
```

## Zig FFI

```zig
// Set backend for the last registered cartridge (default: "universal")
pub export fn boj_catalogue_set_backend(ptr: [*]const u8, len: usize) c_int;

// Query backend label for a cartridge by index
pub export fn boj_menu_backend(index: usize, out_ptr: [*]u8, out_len: usize) usize;
```
