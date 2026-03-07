<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-03-07 -->

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
    │  Federation.idr │  │  fleet_ffi.zig      │  │  order-ticket.scm │
    │                 │  │  nesy_ffi.zig       │  │  matrix view      │
    │  SafeFleet.idr  │  │  database_ffi.zig   │  │  cartridge detail │
    │  SafeReasoning  │  │  agent_ffi.zig      │  │                   │
    │  SafeDatabase   │  │                     │  │                   │
    │  SafeOODA.idr   │  │                     │  │                   │
    └─────────────────┘  └─────────────────────┘  └───────────────────┘
```

## 2D Capability Matrix

```
              MCP    LSP    DAP    BSP    NeSy  Agentic  Fleet   gRPC   REST
           ┌──────┬──────┬──────┬──────┬──────┬───────┬──────┬──────┬──────┐
Database   │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Fleet      │  ██  │      │      │      │      │       │  ██  │      │  ██  │
NeSy       │  ██  │      │      │      │  ██  │       │      │      │  ██  │
Agent      │  ██  │      │      │      │      │  ██   │      │  ██  │  ██  │
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

  ██ = ABI + FFI + Adapter complete (4 cartridges, multi-protocol)
```

## Completion Dashboard

| Component                    | Progress                  | Grade |
|------------------------------|---------------------------|-------|
| Core Catalogue ABI (Idris2)  | `██████████` 100%         | B (RC) |
| Core Catalogue FFI (Zig)     | `██████████` 100%         | B (RC) |
| Dynamic Loader (Zig)         | `██████████` 100%         | C (Beta) |
| V-lang Adapter (REST+gRPC+GQL) | `██████████` 100%      | C (Beta) |
| database-mcp ABI+FFI+Adapter | `██████████` 100%         | D (Alpha) |
| fleet-mcp ABI+FFI+Adapter    | `██████████` 100%         | D (Alpha) |
| nesy-mcp ABI+FFI+Adapter     | `██████████` 100%         | D (Alpha) |
| agent-mcp ABI+FFI+Adapter    | `██████████` 100%         | D (Alpha) |
| Readiness tests (CRG D/C/B)  | `██████████` 100%         | B (RC) |
| Benchmarks                    | `██████████` 100%         | B (RC) |
| CI pipeline (zig-test.yml)    | `██████████` 100%         | D (Alpha) |
| TOPOLOGY.md                   | `██████████` 100%         | Complete |
| Umoja federation              | `░░░░░░░░░░`   0%         | X |
| Matrix fill (remaining)       | `░░░░░░░░░░`   0%         | X |
| Polystack deprecation         | `░░░░░░░░░░`   0%         | X |

## Key Dependencies

| Dependency       | Purpose                          | Status    |
|------------------|----------------------------------|-----------|
| Zig 0.15.2       | FFI compilation                  | Available |
| Idris2           | ABI formal proofs                | Available |
| V-lang 0.5.0     | Network adapter                  | Available |
| proven-servers   | Reference cartridge catalogue    | Active    |
| polystack        | Capability domain mapping (deprecation target) | Available |
| stapeln          | Container supply chain           | Available |
| PanLL            | Panel framework for matrix display | Planned   |
| gitbot-fleet     | 6-bot release gate               | Available |
| hypatia          | Neurosymbolic CI scanning        | Available |
