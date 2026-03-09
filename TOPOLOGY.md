<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-03-09 (18 cartridges, 218+ tests, 18 .so files, Grade C Beta) -->

# Bundle of Joy Server — Project Topology

## System Architecture

```
                      ┌─────────────────────────────────┐
                      │          AI / PanLL              │
                      │  (reads Teranga menu, places     │
                      │   orders for cartridges)         │
                      │  [Panel: COMPLETE — 887 lines]   │
                      │  [bojRouting: 10 panels wired]   │
                      └──────────────┬──────────────────┘
                                     │ Order-Ticket Protocol
                                     ▼
    ┌────────────────────────────────────────────────────────────┐
    │                    BOJ CATALOGUE                           │
    │                                                            │
    │  ┌───────────┐  ┌────────────┐  ┌───────────────────────┐ │
    │  │ Teranga   │  │ Order      │  │ Umoja Federation      │ │
    │  │ Menu      │  │ Ticket     │  │ (QUIC+UDP, 30+ tests  │ │
    │  │ (A2ML)    │  │ (SCM)      │  │  hash attestation)    │ │
    │  └─────┬─────┘  └─────┬──────┘  └──────────┬────────────┘ │
    │        │              │                     │              │
    │  ┌─────▼──────────────▼─────────────────────▼────────────┐ │
    │  │              Catalogue.idr                             │ │
    │  │  (IsUnbreakable proof, 18 matrix cells,               │ │
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
 │  Catalogue.idr   │ │  catalogue.zig    │ │  REST  (7700)      │
 │  Protocol.idr    │ │  loader.zig       │ │  gRPC  (7701)      │
 │  Domain.idr      │ │  federation.zig   │ │  GraphQL (7702)    │
 │  Menu.idr        │ │  verisimdb.zig    │ │                    │
 │  Federation.idr  │ │  guardian.zig     │ │  order-ticket.scm  │
 │  Guardian.idr    │ │  readiness.zig    │ │  matrix view       │
 │                  │ │  bench.zig        │ │  cartridge detail  │
 │  + 18 cartridge  │ │  e2e_order.zig    │ │                    │
 │    ABI modules   │ │  + 18 cartridge   │ │                    │
 │    (20 .idr)     │ │    FFI modules    │ │                    │
 │                  │ │    (54 .zig)      │ │                    │
 └──────────────────┘ └──────────────────┘ └────────────────────┘
           │                  │                      │
           ▼                  ▼                      ▼
 ┌───────────────────────────────────────────────────────────────┐
 │                  18 CARTRIDGES (2D Matrix)                    │
 │                                                               │
 │  database-mcp   fleet-mcp     nesy-mcp      agent-mcp        │
 │  cloud-mcp      container-mcp k8s-mcp       git-mcp          │
 │  secrets-mcp    queues-mcp    iac-mcp       observe-mcp      │
 │  ssg-mcp        proof-mcp     lsp-mcp       dap-mcp          │
 │  bsp-mcp        feedback-mcp                                 │
 │                                                               │
 │  Each: abi/ (Idris2) + ffi/ (Zig) + adapter/ (V-lang)       │
 │  18/18 have .so builds  |  218+ tests total                  │
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
Feedback   │  ██  │      │      │      │      │       │      │  ██  │  ██  │
           └──────┴──────┴──────┴──────┴──────┴───────┴──────┴──────┴──────┘

  ██ = ABI + FFI + Adapter complete (18 cartridges, multi-protocol)
```

## Completion Dashboard

| Component                        | Progress                  | Status         |
|----------------------------------|---------------------------|----------------|
| **Core Infrastructure**          |                           |                |
| Core Catalogue ABI (Idris2)      | `██████████` 100%         | C (Beta)       |
| Core Catalogue FFI (Zig)         | `██████████` 100%         | C (Beta)       |
| Dynamic Loader (Zig)             | `██████████` 100%         | C (Beta)       |
| Guardian module (Zig)            | `██████████` 100%         | C (Beta)       |
| V-lang Adapter (REST+gRPC+GQL)   | `██████████` 100%         | C (Beta)       |
| C Headers (generated)            | `██████████` 100%         | C (Beta)       |
| **Cartridges (18/18 built)**     |                           |                |
| database-mcp                     | `██████████` 100%         | C (Beta) .so — VeriSimDB e2e |
| fleet-mcp                        | `██████████` 100%         | D (Alpha) .so  |
| nesy-mcp                         | `██████████` 100%         | D (Alpha) .so  |
| agent-mcp                        | `██████████` 100%         | D (Alpha) .so  |
| cloud-mcp                        | `██████████` 100%         | D (Alpha) .so  |
| container-mcp                    | `██████████` 100%         | C (Beta) .so — Stapeln wired |
| k8s-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| git-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| secrets-mcp                      | `██████████` 100%         | D (Alpha) .so  |
| queues-mcp                       | `██████████` 100%         | D (Alpha) .so  |
| iac-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| observe-mcp                      | `██████████` 100%         | D (Alpha) .so  |
| ssg-mcp                          | `██████████` 100%         | C (Beta) .so — Zola e2e |
| proof-mcp                        | `██████████` 100%         | D (Alpha) .so  |
| lsp-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| dap-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| bsp-mcp                          | `██████████` 100%         | D (Alpha) .so  |
| feedback-mcp                     | `██████████` 100%         | D (Alpha) .so  |
| **Federation & Distribution**    |                           |                |
| Umoja federation (QUIC+UDP)      | `██████████` 100%         | C (Beta)       |
| VeriSimDB backing store          | `██████████` 100%         | C (Beta)       |
| Hash attestation                 | `██████████` 100%         | C (Beta)       |
| Gossip protocol                  | `██████████` 100%         | C (Beta)       |
| **Dogfooding (Grade C)**         |                           |                |
| VeriSimDB through database-mcp   | `██████████` 100%         | Tested e2e     |
| Zola/ddraig through ssg-mcp     | `██████████` 100%         | Tested e2e     |
| Stapeln through container-mcp   | `██████████` 100%         | Wired          |
| feedback-o-tron (18th cartridge) | `██████████` 100%         | Full ABI+FFI   |
| PanLL BoJ panel                  | `██████████` 100%         | 887 lines, 5 tabs |
| PanLL bojRouting (10 panels)     | `██████████` 100%         | Conditional dispatch |
| **Testing (218+ total)**         |                           |                |
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
| Containerfile (Chainguard)       | `██████████` 100%         | 18 cartridges  |
| selur-compose orchestration      | `██████████` 100%         | Present        |
| vordr runtime monitoring         | `██████████` 100%         | Present        |
| **Integration**                  |                           |                |
| PanLL BoJ panel                  | `██████████` 100%         | Complete       |
| Teranga menu runtime             | `███░░░░░░░`  30%         | Spec only      |
| READINESS.md                     | `██████████` 100%         | Current        |
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

**Overall: Grade C Beta — Dogfooding 6/7 complete**

What is genuinely done:
- 18 cartridges with ABI+FFI+Adapter structure (3 at Grade C, 15 at Grade D)
- 18/18 cartridges have compiled .so shared libraries
- 218+ tests passing (105 core + 113 cartridge + 30 federation + 12 guardian + 28 readiness + 7 VeriSimDB + 3 e2e)
- Umoja federation with real UDP networking and 30 tests
- Guardian resource-aware failure tolerance (12 tests)
- VeriSimDB backing store e2e through database-mcp (octad CRUD, VQL, drift)
- Stapeln integration through container-mcp (FFI state machine + API proxy)
- Zola/ddraig builds through ssg-mcp (end-to-end)
- feedback-o-tron as 18th cartridge (full stack)
- PanLL bojRouting wired on 10 panels with conditional dispatch
- Complete container ecosystem (Containerfile, compose.toml, vordr.toml)
- CI pipeline active
- Zero believe_me in actual code
- PanLL BoJ panel fully implemented (887 lines, 5 tabs) in PanLL repo
- hexad→octad rename complete across VeriSimDB, BoJ, PanLL

Grade C→B requirements:
- QUIC-first transport for Umoja federation (replace cleartext UDP)
- Multi-node federation testing
- Coprocessor dispatch (Axiom.jl-style GPU/TPU/FPGA)
- Podman secure instance for community node operators
- Documentation and stable API contract
