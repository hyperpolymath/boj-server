<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- TOPOLOGY.md — Project architecture map and completion dashboard -->
<!-- Last updated: 2026-03-20 (55 cartridges total, 18 core with ABI+FFI+Adapter, 307 tests, 18 .so files, Grade D Alpha) -->

# Bundle of Joy Server — Project Topology

## System Architecture

```
                      ┌─────────────────────────────────┐
                      │          AI / PanLL              │
                      │  (reads Teranga menu, places     │
                      │   orders for cartridges)         │
                      │  [Panel: COMPLETE — 887 lines]   │
                      │  [bojRouting: 10 panels wired]   │
                      │  [55/55 cartridges have panels]  │
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
 │                  │ │  coprocessor.zig  │ │  cartridge detail  │
 │  + 18 cartridge  │ │  bench.zig        │ │                    │
 │    ABI modules   │ │  e2e_order.zig    │ │                    │
 │    (20 .idr)     │ │  + 18 cartridge   │ │                    │
 │                  │ │    (54 .zig)      │ │                    │
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
 │  18/18 core mounted + serving  |  307 tests total              │
│  55 total cartridges (37 community/provider-specific)         │
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
 │  feedback-o-tron (18th cartridge — separate)                  │
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
Container  │  ██  │      │      │      │      │       │      │      │  ██  │
K8s        │  ██  │      │      │      │      │       │      │  ██  │  ██  │
Git/VCS    │  ██  │      │      │      │      │       │      │      │  ██  │
Secrets    │  ██  │      │      │      │      │       │      │      │  ██  │
Queues     │  ██  │      │      │      │      │       │      │  ██  │  ██  │
IaC        │  ██  │      │      │      │      │       │      │      │  ██  │
Observe    │  ██  │      │      │      │      │       │      │  ██  │  ██  │
SSG        │  ██  │      │      │      │      │       │      │      │  ██  │
Proof      │  ██  │      │      │      │      │       │      │      │  ██  │
LSP        │  ██  │  ██  │      │      │      │       │      │      │  ██  │
DAP        │  ██  │      │  ██  │      │      │       │      │      │  ██  │
BSP        │  ██  │      │      │  ██  │      │       │      │      │  ██  │
           └──────┴──────┴──────┴──────┴──────┴───────┴──────┴──────┴──────┘

  ██ = ABI + FFI + Adapter built and .so compiled (Grade D Alpha)
  gRPC on: database, agent, cloud, k8s, queues, observe (6/17)
  All cells have backend="universal". Third axis (backend/provider)
  stubbed for community extensions — see docs/EXTENSIBILITY.md
```

## Completion Dashboard

| Component                        | Progress                  | Status         |
|----------------------------------|---------------------------|----------------|
| **Core Infrastructure**          |                           |                |
| Core Catalogue ABI (Idris2)      | `████████░░`  80%         | D (Alpha) — type-checks, no runtime tests |
| Core Catalogue FFI (Zig)         | `████████░░`  80%         | D (Alpha) — builds, tests pass, no real protocol integration |
| Dynamic Loader (Zig)             | `███████░░░`  70%         | D (Alpha) — hash verify works, no production load testing |
| Guardian module (Zig)            | `███████░░░`  70%         | D (Alpha) — 12 tests, no real failure scenarios |
| V-lang Adapter (REST+gRPC+GQL)   | `██████░░░░`  60%         | D (Alpha) — compiles and routes, no external traffic |
| C Headers (generated)            | `███████░░░`  70%         | D (Alpha) — generated, not tested via C consumer |
| **Cartridges (17/17 built)**     |                           |                |
| database-mcp                     | `███████░░░`  70%         | D (Alpha) .so — e2e test exists, no real DB workload |
| fleet-mcp                        | `██████░░░░`  60%         | D (Alpha) .so  |
| nesy-mcp                         | `██████░░░░`  60%         | D (Alpha) .so  |
| agent-mcp                        | `██████░░░░`  60%         | D (Alpha) .so  |
| cloud-mcp                        | `██████░░░░`  60%         | D (Alpha) .so  |
| container-mcp                    | `██████░░░░`  60%         | D (Alpha) .so — Stapeln wired, not e2e tested |
| k8s-mcp                          | `██████░░░░`  60%         | D (Alpha) .so  |
| git-mcp                          | `██████░░░░`  60%         | D (Alpha) .so  |
| secrets-mcp                      | `██████░░░░`  60%         | D (Alpha) .so  |
| queues-mcp                       | `██████░░░░`  60%         | D (Alpha) .so  |
| iac-mcp                          | `██████░░░░`  60%         | D (Alpha) .so  |
| observe-mcp                      | `██████░░░░`  60%         | D (Alpha) .so  |
| ssg-mcp                          | `██████░░░░`  60%         | D (Alpha) .so — Zola e2e test exists, not production |
| proof-mcp                        | `██████░░░░`  60%         | D (Alpha) .so  |
| lsp-mcp                          | `███████░░░`  70%         | D (Alpha) .so — dedicated CI (lsp-dap-bsp.yml) |
| dap-mcp                          | `███████░░░`  70%         | D (Alpha) .so — dedicated CI (lsp-dap-bsp.yml) |
| bsp-mcp                          | `███████░░░`  70%         | D (Alpha) .so — dedicated CI (lsp-dap-bsp.yml) |
| **Specialist Cartridges**        |                           |                |
| feedback-o-tron (18th cartridge) | `██████░░░░`  60%         | D (Alpha) — full ABI+FFI, not collecting real feedback |
| **Federation & Distribution**    |                           |                |
| Umoja federation (QUIC+UDP)      | `██████░░░░`  60%         | D (Alpha) — tests pass, no real multi-node deployment |
| VeriSimDB backing store          | `██████░░░░`  60%         | D (Alpha) — 7 tests, no production persistence |
| Hash attestation                 | `██████░░░░`  60%         | D (Alpha) — implemented, not validated externally |
| Gossip protocol                  | `██████░░░░`  60%         | D (Alpha) — tested locally, no real network |
| **Internal Integration**         |                           |                |
| VeriSimDB through database-mcp   | `██████░░░░`  60%         | D (Alpha) — e2e test, not dogfooded |
| Zola/ddraig through ssg-mcp     | `██████░░░░`  60%         | D (Alpha) — e2e test, not dogfooded |
| Stapeln through container-mcp   | `████░░░░░░`  40%         | D (Alpha) — wired, not tested end-to-end |
| feedback-o-tron (18th cartridge) | `██████░░░░`  60%         | D (Alpha) — full ABI+FFI, not collecting real feedback |
| PanLL BoJ panel                  | `███████░░░`  70%         | D (Alpha) — 887 lines, 5 tabs, not tested with live data |
| PanLL bojRouting (10 panels)     | `███████░░░`  70%         | D (Alpha) — conditional dispatch, no live traffic |
| PanLL panel manifests (55/55)    | `██████████` 100%         | All cartridges have panel manifests              |
| **Testing (307 total)**         |                           |                |
| Core FFI tests (176)             | `██████████` 100%         | Passing        |
| Cartridge FFI tests (113)        | `██████████` 100%         | Passing        |
| Federation tests (30)            | `██████████` 100%         | Passing        |
| Guardian tests (12)              | `██████████` 100%         | Passing        |
| Readiness tests (28)             | `██████████` 100%         | Passing        |
| VeriSimDB tests (7)              | `██████████` 100%         | Passing        |
| E2E order-ticket tests (3)       | `██████████` 100%         | Passing        |
| Benchmarks                       | `██████████` 100%         | Available      |
| **CI/CD & Container**            |                           |                |
| CI pipeline (zig-test.yml)       | `██████████` 100%         | Active         |
| CI pipeline (lsp-dap-bsp.yml)   | `██████████` 100%         | Dedicated LSP/DAP/BSP CI |
| Containerfile (Chainguard)       | `███████░░░`  70%         | D (Alpha) — present, no e2e container test |
| selur-compose orchestration      | `█████░░░░░`  50%         | D (Alpha) — file present, not validated |
| vordr runtime monitoring         | `█████░░░░░`  50%         | D (Alpha) — file present, not validated |
| **Integration**                  |                           |                |
| PanLL BoJ panel                  | `███████░░░`  70%         | D (Alpha) — code complete, no live data |
| Teranga menu runtime             | `██░░░░░░░░`  20%         | X (Untested) — spec only, no runtime |
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

**Overall: Grade D (Alpha) — State machines built, tests passing, no external validation**

What is genuinely done:
- 18 cartridges with ABI+FFI+Adapter structure (all at Grade D Alpha)
- 18/18 cartridges have compiled .so shared libraries
- 307 tests passing (178 core Zig [13 catalogue + 14 loader + 40 federation + 12 guardian + 28 readiness + 7 VeriSimDB + 3 e2e + 14 coprocessor + 11 SLA + 11 community + 10 SDP + 15 seams] + 118 cartridge FFI + 11 multi-node)
- Thread-safety hardening: std.Thread.Mutex on all 9 FFI modules (55 globals, 120 exports)
- panic-attack assail: 1 weak point (QUIC crypto, expected), 0 critical Zig vulns, 0 cross-language vulns
- MCP stdio bridge (boj-server --mcp, JSON-RPC 2.0, all 18 cartridges as MCP tools)
- Seam checks (panic-attack–style integration contract validation, 13 tests, silent signature)
- Third-axis extensibility (backend/provider dimension) stubbed for community extensions
- Umoja federation with QUIC-first transport (X25519+ChaCha20-Poly1305, UDP fallback, 40 tests)
- Multi-node federation testing (11 tests, REST API for peer management)
- Coprocessor dispatch (Axiom.jl-style: detect→select→dispatch→fallback, 14 tests)
- Guardian resource-aware failure tolerance (12 tests)
- VeriSimDB backing store e2e through database-mcp (octad CRUD, VQL, drift)
- Stapeln integration through container-mcp (FFI state machine + API proxy)
- Zola/ddraig builds through ssg-mcp (end-to-end)
- feedback-o-tron as 18th cartridge (full stack)
- PanLL bojRouting wired on 10 panels with conditional dispatch
- Podman secure instance for community nodes (quadlet, seccomp, read-only rootfs)
- Complete container ecosystem (Containerfile, compose.toml, vordr.toml)
- Stable API contract (docs/API-CONTRACT.md)
- Configurable ports via environment variables
- CI pipeline active
- Zero believe_me in actual code
- PanLL BoJ panel fully implemented (887 lines, 5 tabs) in PanLL repo
- hexad→octad rename complete across VeriSimDB, BoJ, PanLL

- SLA monitoring (3-tier: community/standard/premium, percentile tracking, 11 tests)
- Community cartridge submissions (Ayo tier, review state machine, 11 tests)
- Auto-SDP perimeter (zero-trust, allow-list, auto-ban, 10 tests)
- 4-continent seed node config (EU-West, EU-Central, US-East, AP-South)

## Architecture Documentation

| Document | Path | Coverage |
|----------|------|----------|
| Quantum Security | `docs/architecture/QUANTUM_SECURITY.adoc` | PQC roadmap, hybrid signatures |
| HSM Integration | `docs/architecture/HSM_INTEGRATION.adoc` | PKCS#11, YubiHSM, CloudHSM |
| Cartridge Marketplace | `docs/architecture/CARTRIDGE_MARKETPLACE.adoc` | Discovery, quality signals, ratings |
| BoJ OS | `docs/architecture/BOJ_OS.adoc` | Lightweight node OS (<100MB) |
| Formal Verification | `docs/architecture/FORMAL_VERIFICATION.adoc` | Idris2/Lean/TLA+ strategy |
| Type Safety | `docs/architecture/TYPE_SAFETY.adoc` | Cross-language type mappings |
| Zero Trust | `docs/architecture/ZERO_TRUST.adoc` | SPIFFE/SPIRE, mTLS, OPA |
| SDP Architecture | `docs/architecture/SDP_ARCHITECTURE.adoc` | QUIC proxy, geo-redundancy |
| Gossip Protocol | `docs/architecture/GOSSIP_PROTOCOL.adoc` | Umoja gossip protocol details |
| Cartridge Tools | `docs/specification/cartridge-tools/README.md` | Minter, Provisioner, Configurator, Panel Harness |

Remaining:
- Deploy seed nodes to actual infrastructure
- Domain registration for named Cloudflare tunnel
- OpenSSF CII badge registration
- OSS-Fuzz integration
