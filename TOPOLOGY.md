<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-03-09 (17 cartridges, 218 tests, 17 .so files) -->

# Bundle of Joy Server — Project Topology

## System Architecture

```
                      ┌─────────────────────────────────┐
                      │          AI / PanLL              │
                      │  (reads Teranga menu, places     │
                      │   orders for cartridges)         │
                      │  [Panel: COMPLETE — 887 lines]   │
                      └──────────────┬──────────────────┘
                                     │ Order-Ticket Protocol
                                     ▼
    ┌────────────────────────────────────────────────────────────┐
    │                    BOJ CATALOGUE                           │
    │                                                            │
    │  ┌───────────┐  ┌────────────┐  ┌───────────────────────┐ │
    │  │ Teranga   │  │ Order      │  │ Umoja Federation      │ │
    │  │ Menu      │  │ Ticket     │  │ (UDP gossip, 30 tests │ │
    │  │ (A2ML)    │  │ (SCM)      │  │  hash attestation)    │ │
    │  └─────┬─────┘  └─────┬──────┘  └──────────┬────────────┘ │
    │        │              │                     │              │
    │  ┌─────▼──────────────▼─────────────────────▼────────────┐ │
    │  │              Catalogue.idr                             │ │
    │  │  (IsUnbreakable proof, 17 matrix cells,               │ │
    │  │   Protocol x Domain cartridge registry)               │ │
    │  └──────────────────────┬────────────────────────────────┘ │
    │                         │                                  │
    │  ┌──────────────────────▼────────────────────────────────┐ │
    │  │              Guardian.idr                              │ │
    │  │  (Resource-aware failure tolerance, 12 tests)         │ │
    │  └──────────────────────┬────────────────────────────────┘ │
    └─────────────────────────┼──────────────────────────────────┘
                              │
           ┌──────────────────┼──────────────────────┐
           │                  │                      │
 ┌─────────▼───────┐ ┌───────▼──────────┐ ┌─────────▼──────────┐
 │  ABI Layer       │ │  FFI Layer        │ │  Adapter Layer     │
 │  (Idris2)        │ │  (Zig)            │ │  (V-lang)          │
 │                  │ │                   │ │                    │
 │  Catalogue.idr   │ │  catalogue.zig    │ │  REST  (9000)      │
 │  Protocol.idr    │ │  loader.zig       │ │  gRPC  (9001)      │
 │  Domain.idr      │ │  federation.zig   │ │  GraphQL (9002)    │
 │  Menu.idr        │ │  verisimdb.zig    │ │                    │
 │  Federation.idr  │ │  guardian.zig     │ │  order-ticket.scm  │
 │  Guardian.idr    │ │  readiness.zig    │ │  matrix view       │
 │                  │ │  bench.zig        │ │  cartridge detail  │
 │  + 17 cartridge  │ │  e2e_order.zig    │ │                    │
 │    ABI modules   │ │  + 17 cartridge   │ │                    │
 │    (19 .idr)     │ │    FFI modules    │ │                    │
 │                  │ │    (51 .zig)      │ │                    │
 └──────────────────┘ └──────────────────┘ └────────────────────┘
           │                  │                      │
           ▼                  ▼                      ▼
 ┌───────────────────────────────────────────────────────────────┐
 │                  17 CARTRIDGES (2D Matrix)                    │
 │                                                               │
 │  database-mcp   fleet-mcp     nesy-mcp      agent-mcp        │
 │  cloud-mcp      container-mcp k8s-mcp       git-mcp          │
 │  secrets-mcp    queues-mcp    iac-mcp       observe-mcp      │
 │  ssg-mcp        proof-mcp     lsp-mcp       dap-mcp          │
 │  bsp-mcp                                                     │
 │                                                               │
 │  Each: abi/ (Idris2) + ffi/ (Zig) + adapter/ (V-lang)       │
 │  17/17 have .so builds  |  218 tests total                   │
 └───────────────────────────────────────────────────────────────┘
           │
           ▼
 ┌───────────────────────────────────────────────────────────────┐
 │              CONTAINER / DEPLOYMENT                           │
 │                                                               │
 │  Containerfile (Chainguard base)                              │
 │  compose.toml (selur-compose)                                 │
 │  vordr.toml (runtime monitoring)                              │
 │  deploy.k9.ncl (operational constraints)                      │
 │  VeriSimDB backing store (7 tests)                            │
 └───────────────────────────────────────────────────────────────┘
```

## 2D Capability Matrix

```
              MCP    LSP    DAP    BSP    NeSy  Agentic  Fleet   gRPC   REST
           ┌──────┬──────┬──────┬──────┬──────┬───────┬──────┬──────┬──────┐
Database   │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Fleet      │  ██  │      │      │      │      │       │  ██  │      │  ██  │
NeSy       │  ██  │      │      │      │  ██  │       │      │      │  ██  │
Agent      │  ██  │      │      │      │      │  ██   │      │  ██  │  ██  │
Cloud      │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Container  │  ██  │      │      │      │      │       │      │  ██  │  ██  │
K8s        │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Git/VCS    │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Secrets    │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Queues     │  ██  │      │      │      │      │       │      │  ██  │  ██  │
IaC        │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Observe    │  ██  │      │      │      │      │       │      │  ██  │  ██  │
SSG        │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Proof      │  ██  │      │      │      │      │       │      │  ██  │  ██  │
LSP        │  ██  │  ██  │      │      │      │       │      │  ██  │  ██  │
DAP        │  ██  │      │  ██  │      │      │       │      │  ██  │  ██  │
BSP        │  ██  │      │      │  ██  │      │       │      │  ██  │  ██  │
           └──────┴──────┴──────┴──────┴──────┴───────┴──────┴──────┴──────┘

  ██ = ABI + FFI + Adapter complete (17 cartridges, multi-protocol)
```

## Completion Dashboard

| Component                        | Progress                  | Status         |
|----------------------------------|---------------------------|----------------|
| **Core Infrastructure**          |                           |                |
| Core Catalogue ABI (Idris2)      | `██████████` 100%         | D (Alpha)      |
| Core Catalogue FFI (Zig)         | `██████████` 100%         | D (Alpha)      |
| Dynamic Loader (Zig)             | `██████████` 100%         | D (Alpha)      |
| Guardian module (Zig)            | `██████████` 100%         | D (Alpha)      |
| V-lang Adapter (REST+gRPC+GQL)   | `██████████` 100%         | D (Alpha)      |
| C Headers (generated)            | `██████████` 100%         | D (Alpha)      |
| **Cartridges (17/17 built)**     |                           |                |
| database-mcp                     | `██████████` 100%         | D (Alpha) .so  |
| fleet-mcp                        | `██████████` 100%         | D (Alpha) .so  |
| nesy-mcp                         | `██████████` 100%         | D (Alpha) .so  |
| agent-mcp                        | `██████████` 100%         | D (Alpha) .so  |
| cloud-mcp                        | `██████████` 100%         | D (Alpha) .so  |
| container-mcp                    | `██████████` 100%         | D (Alpha) .so  |
| k8s-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| git-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| secrets-mcp                      | `██████████` 100%         | D (Alpha) .so  |
| queues-mcp                       | `██████████` 100%         | D (Alpha) .so  |
| iac-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| observe-mcp                      | `██████████` 100%         | D (Alpha) .so  |
| ssg-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| proof-mcp                        | `██████████` 100%         | D (Alpha) .so  |
| lsp-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| dap-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| bsp-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| **Federation & Distribution**    |                           |                |
| Umoja federation (real UDP)      | `██████████` 100%         | D (Alpha)      |
| VeriSimDB backing store          | `██████████` 100%         | D (Alpha)      |
| Hash attestation                 | `██████████` 100%         | D (Alpha)      |
| Gossip protocol                  | `██████████` 100%         | D (Alpha)      |
| **Testing (218 total)**          |                           |                |
| Core FFI tests (105)             | `██████████` 100%         | Passing        |
| Cartridge FFI tests (113)        | `██████████` 100%         | Passing        |
| Federation tests (30)            | `██████████` 100%         | Passing        |
| Guardian tests (12)              | `██████████` 100%         | Passing        |
| Readiness tests (28)             | `██████████` 100%         | Passing        |
| VeriSimDB tests (7)              | `██████████` 100%         | Passing        |
| E2E order-ticket tests (3)       | `██████████` 100%         | Passing        |
| Benchmarks                       | `██████████` 100%         | Available      |
| **CI/CD & Container**            |                           |                |
| CI pipeline (zig-test.yml)       | `██████████` 100%         | Active         |
| Containerfile (Chainguard)       | `██████████` 100%         | Present        |
| selur-compose orchestration      | `██████████` 100%         | Present        |
| vordr runtime monitoring         | `██████████` 100%         | Present        |
| Container e2e test               | `░░░░░░░░░░`   0%         | Not started    |
| **Integration**                  |                           |                |
| PanLL BoJ panel                  | `██████████` 100%         | Complete (887 lines, 5 tabs) |
| Teranga menu runtime             | `███░░░░░░░`  30%         | Spec only      |
| READINESS.md                     | `██████████` 100%         | Current (2026-03-09) |
| Polystack deprecation            | `██████████` 100%         | Archived       |

## Key Dependencies

| Dependency       | Purpose                          | Status    |
|------------------|----------------------------------|-----------|
| Zig 0.15.2       | FFI compilation                  | Available |
| Idris2           | ABI formal proofs                | Available |
| V-lang 0.5.0     | Network adapter                  | Available |
| proven-servers   | Reference cartridge catalogue    | Active    |
| polystack        | Capability domain mapping (DEPRECATED 2026-03-08) | Archived |
| stapeln          | Container supply chain           | Available |
| PanLL            | Panel framework for matrix display | Active   |
| gitbot-fleet     | 6-bot release gate               | Available |
| hypatia          | Neurosymbolic CI scanning        | Available |
| VeriSimDB        | Backing store for cartridge state | Available |

## Honest Assessment (2026-03-09)

**Overall: ~100% complete for v0.2.0 scope**

What is genuinely done:
- 17 cartridges with ABI+FFI+Adapter structure (all Grade D Alpha)
- 17/17 cartridges have compiled .so shared libraries
- 218 tests passing (105 core + 113 cartridge + 30 federation + 12 guardian + 28 readiness + 7 VeriSimDB + 3 e2e)
- Umoja federation with real UDP networking and 30 tests
- Guardian resource-aware failure tolerance (12 tests)
- VeriSimDB backing store integration (7 tests)
- Complete container ecosystem (Containerfile, compose.toml, vordr.toml)
- CI pipeline active
- Zero believe_me in actual code
- PanLL BoJ panel fully implemented (887 lines, 5 tabs) in PanLL repo
- READINESS.md current (2026-03-09)

Remaining stretch goals (not blockers for v0.2.0):
- Teranga menu has no runtime generation (spec only)
- Container ecosystem not tested end-to-end
- No multi-node integration tests
- Grade D -> C requires dogfooding with a real project
