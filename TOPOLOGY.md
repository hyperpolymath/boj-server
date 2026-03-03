<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-03-03 -->

# Bundle of Joy Server — Project Topology

## System Architecture

```
                           ┌──────────────────────────┐
                           │       AI / PanLL          │
                           │  (reads menu, places      │
                           │   orders for cartridges)  │
                           └────────────┬─────────────┘
                                        │ Order-Ticket Protocol
                                        ▼
               ┌────────────────────────────────────────────────┐
               │              BOJ CATALOGUE                      │
               │                                                 │
               │  ┌──────────┐  ┌──────────┐  ┌──────────────┐ │
               │  │ Teranga  │  │ Order    │  │ Federation   │ │
               │  │ Menu     │  │ Ticket   │  │ (Umoja       │ │
               │  │ (A2ML)   │  │ (SCM)    │  │  Gossip)     │ │
               │  └────┬─────┘  └────┬─────┘  └──────┬───────┘ │
               │       │             │               │          │
               │  ┌────▼─────────────▼───────────────▼───────┐ │
               │  │           Catalogue.idr                   │ │
               │  │  (IsUnbreakable proof, matrix cells,      │ │
               │  │   Protocol × Domain cartridge registry)   │ │
               │  └────────────────────┬─────────────────────┘ │
               └───────────────────────┼────────────────────────┘
                                       │
              ┌────────────────────────┼────────────────────────┐
              │                        │                         │
    ┌─────────▼──────┐  ┌─────────────▼──────┐  ┌──────────────▼────┐
    │  ABI Layer      │  │  FFI Layer          │  │  Adapter Layer    │
    │  (Idris2)       │  │  (Zig)              │  │  (V-lang)         │
    │                 │  │                     │  │                   │
    │  Catalogue.idr  │  │  catalogue.zig      │  │  REST  (9000)     │
    │  Protocol.idr   │  │  loader.zig         │  │  gRPC  (9001)     │
    │  Domain.idr     │  │  boj_catalogue.h    │  │  GraphQL (9002)   │
    │  Menu.idr       │  │                     │  │                   │
    │  Federation.idr │  │  fleet_ffi.zig      │  │  (Phase 3)        │
    │                 │  │  nesy_ffi.zig       │  │                   │
    │  SafeFleet.idr  │  │  database_ffi.zig   │  │                   │
    │  SafeReasoning  │  │  agent_ffi.zig      │  │                   │
    │  SafeDatabase   │  │                     │  │                   │
    │  SafeOODA.idr   │  │                     │  │                   │
    └─────────────────┘  └─────────────────────┘  └───────────────────┘
```

## 2D Capability Matrix

```
              MCP    LSP    DAP    BSP    NeSy  Agentic  Fleet   gRPC   REST
           ┌──────┬──────┬──────┬──────┬──────┬───────┬──────┬──────┬──────┐
Database   │  ██  │      │      │      │      │       │      │      │      │
Fleet      │  ██  │      │      │      │      │       │      │      │      │
NeSy       │  ██  │      │      │      │      │       │      │      │      │
Agent      │  ██  │      │      │      │      │       │      │      │      │
Cloud      │      │      │      │      │      │       │      │      │      │
Container  │      │      │      │      │      │       │      │      │      │
K8s        │      │      │      │      │      │       │      │      │      │
Git/VCS    │      │      │      │      │      │       │      │      │      │
Secrets    │      │      │      │      │      │       │      │      │      │
Queues     │      │      │      │      │      │       │      │      │      │
IaC        │      │      │      │      │      │       │      │      │      │
Observe    │      │      │      │      │      │       │      │      │      │
SSG        │      │      │      │      │      │       │      │      │      │
Proof      │      │      │      │      │      │       │      │      │      │
           └──────┴──────┴──────┴──────┴──────┴───────┴──────┴──────┴──────┘

  ██ = ABI + FFI complete (4 cartridges)
```

## Completion Dashboard

| Component              | Progress   | Status       |
|------------------------|------------|--------------|
| Core Catalogue ABI     | `██████████` 100% | Complete |
| Core Catalogue FFI     | `██████████` 100% | Complete |
| C Headers              | `██████████` 100% | Complete |
| database-mcp (ABI+FFI) | `██████████` 100% | Complete |
| fleet-mcp (ABI+FFI)    | `██████████` 100% | Complete |
| nesy-mcp (ABI+FFI)     | `██████████` 100% | Complete |
| agent-mcp (ABI+FFI)    | `██████████` 100% | Complete |
| V-lang Adapter          | `░░░░░░░░░░`   0% | Phase 3  |
| Dynamic Loader          | `█░░░░░░░░░`  10% | Stub     |
| Umoja Federation        | `░░░░░░░░░░`   0% | Phase 5  |
| PanLL Panel             | `░░░░░░░░░░`   0% | Phase 5  |
| Stapeln Container       | `░░░░░░░░░░`   0% | Phase 3  |
| MCP Protocol Endpoint   | `░░░░░░░░░░`   0% | Phase 2  |
| LSP Protocol Endpoint   | `░░░░░░░░░░`   0% | Phase 2  |

## Key Dependencies

| Dependency       | Purpose                          | Status    |
|------------------|----------------------------------|-----------|
| proven-servers   | MCP/LSP type skeletons, connectors | Available |
| polystack        | Capability domain mapping (deprecation target) | Available |
| stapeln          | Container supply chain           | Available |
| PanLL            | Panel framework for matrix display | Available |
| gitbot-fleet     | 6-bot release gate               | Available |
| hypatia          | Neurosymbolic CI scanning        | Available |
