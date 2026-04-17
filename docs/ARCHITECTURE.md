# BoJ Server Architecture

## The Problem

The developer server ecosystem is fragmenting. MCP servers, LSP servers, DAP servers, build servers — each tool has its own server, each AI needs different capabilities. Developers drown in configuration. AI agents hunt across dozens of endpoints.

**BoJ solves this.** AI goes to ONE place — the Teranga menu — and orders what it needs.

## The 2D Capability Matrix

BoJ organises server capabilities as a 2D matrix:

- **Columns** = protocol types (HOW you talk to a server)
- **Rows** = capability domains (WHAT the server does)
- **Cells** = cartridges (formally verified, swappable capability modules)

```
              MCP    LSP    DAP    BSP    NeSy   Agent  Fleet  gRPC   REST
           +------+------+------+------+------+------+------+------+------+
Cloud      |      |      |      |      |      |      |      |      |      |
Container  |      |      |      |      |      |      |      |      |      |
Database   |  *   |  *   |      |      |      |      |      |      |      |
K8s        |      |      |      |      |      |      |      |      |      |
Git/VCS    |      |      |      |      |      |      |      |      |      |
Secrets    |  *   |      |      |      |      |      |      |      |      |
Queues     |      |      |      |      |      |      |      |      |      |
IaC        |      |      |      |      |      |      |      |      |      |
Observe    |  *   |      |      |      |      |      |      |      |      |
SSG        |      |      |      |      |      |      |      |      |      |
Proof      |      |      |      |      |      |      |      |      |      |
Fleet      |  *   |      |      |      |      |      |  *   |  *   |      |
NeSy       |  *   |  *   |      |      |  *   |      |      |  *   |      |
           +------+------+------+------+------+------+------+------+------+

* = cartridge exists (may be Development or Ready)
```

The matrix is sparse — not every cell needs to be filled. The most common use case is MCP+LSP, but the architecture supports any combination.

## Three-Layer Stack (per cartridge)

Every cartridge follows the same three-layer pattern:

| Layer | Language | Purpose |
|-------|----------|---------|
| **ABI** | Idris2 | Formal proofs, state machines, `%default total`, zero `believe_me` |
| **FFI** | Zig | C-compatible native execution, zero runtime dependencies |
| **Adapter** | Zig | Triple API (REST + gRPC + GraphQL) on dedicated ports (see note) |

> **Note (2026-04-10):** V-lang was banned estate-wide on 2026-04-10. The adapter
> layer previously used V-lang; it has been replaced by Zig (`ffi/zig/` adapters,
> swept in commit c4674f8). Historical V-lang API interfaces live in
> `developer-ecosystem/v-ecosystem/v-api-interfaces/` for potential donation to the
> V community — they are not HP infrastructure. The long-term target for the adapter
> layer is the **unified-zig-api stack** (`developer-ecosystem/zig-api/`); see
> [§ Unified-Zig-API Stack](#unified-zig-api-stack) and ADR-0002.

### Why these languages?

**Idris2** has dependent types that prove interface correctness at compile-time. The `IsUnbreakable` proof type mathematically guarantees that only `Ready` cartridges can be activated. This isn't aspirational — it's enforced by the type checker.

**Zig** provides native C ABI compatibility without runtime overhead. It bridges the gap between Idris2's proofs and actual system calls. Cross-compilation is built-in, which matters for community nodes running on varied hardware. Zig now covers both the FFI layer and the adapter (HTTP server) layer.

## The Teranga Menu

The menu (`.machine_readable/servers/menu.a2ml`) is the public catalogue of available capabilities. It has three sections:

- **Teranga (Core)**: Cartridges maintained by the project
- **Shield**: Privacy and security cartridges (SDP, DoQ/DoH, oDNS)
- **Ayo (Community)**: Community-contributed cartridges

AI agents act as the "Maitre D'" — presenting the menu to users, taking their order, and having the kitchen prepare it.

## The Order-Ticket Protocol

1. AI reads the Teranga menu (`menu.a2ml`)
2. AI writes an order ticket (`order-ticket.scm`)
3. BoJ validates the order against the catalogue (checks `IsUnbreakable`)
4. BoJ mounts requested cartridges via Zig FFI
5. Zig adapter exposes mounted cartridges as REST+gRPC+GraphQL
6. AI receives confirmation with endpoints

## Distributed Hosting (Umoja Network)

BoJ servers are community-hosted, like Tor or IPFS:

- Volunteer nodes host BoJ servers during their uptime
- **Hash attestation**: each node's binary hash must match the canonical build
- **Tampered nodes**: excluded from the community network, but can still run locally
- **Gossip protocol**: nodes discover each other via IPv6 gossip (Byzantine fault tolerant)
- **Load-aware routing**: requests go to healthy nodes (under 80% capacity)
- **PMPL provenance**: the license's cryptographic provenance requirements ARE the attestation

### Seed Nodes (Day 1)

- Europe West (UK) — primary development
- Europe Central — community
- Oceania (Australia) — community
- Americas — community

### Node Security

- Stapeln supply chain for container images (Chainguard base, selur-compose)
- Vordr for runtime monitoring and ephemeral ports
- Svalinn edge gateway
- Auto-SDP (Software Defined Perimeter) — zero exposed ports until authenticated
- DNS over QUIC (DoQ) / DNS over HTTPS (DoH) for all traffic
- Oblivious DNS (oDNS) relay option for privacy

## Reusable Foundations

BoJ doesn't start from scratch:

- **proven-servers** (108 components, zero `believe_me`): MCP types, connectors, core primitives
- **polystack** (13 components — being superseded by BoJ): capability domain mapping
- **stapeln**: container supply chain

## Thread Safety

All 9 Zig FFI modules (`database.zig`, `secrets.zig`, `observe.zig`, `fleet.zig`, `nesy.zig`, `federation.zig`, `lsp.zig`, `dap.zig`, `bsp.zig`) use `std.Thread.Mutex` to guarantee safe concurrent access from the Zig HTTP adapter worker threads.

**Mutex discipline:**

- Every `pub export fn` (C-ABI boundary) acquires the module's mutex before touching any global state and releases it on return via `defer`.
- 55 global variables are protected across 120+ exported functions.
- No Zig FFI function can be entered concurrently on two threads with conflicting access to the same global.

**Deadlock prevention:**

Some exported functions need to call other exported functions within the same module (e.g. `federation.zig` where a gossip handler invokes node-lookup logic). If both the caller and callee acquire the same mutex, the thread deadlocks on itself. The solution is a two-tier naming convention:

1. `pub export fn boj_federation_*` — acquires the mutex, called only from the Zig adapter / external C code.
2. `fn federation_*_impl` — mutex-free internal implementation, called by other functions that already hold the lock.

Exported functions delegate to `_impl` helpers, and re-entrant internal call paths use `_impl` directly, so the mutex is acquired exactly once per external call.

**Concurrency model:**

The Zig HTTP adapter spawns worker threads that call into the Zig FFI concurrently. Because every C-ABI entry point serialises on the module mutex, workers never observe torn or partially-updated state. The cost is per-module serialisation, which is acceptable at current scale; future work may introduce per-resource fine-grained locks if profiling warrants it.

**panic-attack validation:**

The panic-attack security scanner validated the thread-safety model across all 9 modules. Results: 1 expected weak point (QUIC crypto — inherent to the protocol's 0-RTT replay window, mitigated at the application layer), 0 critical vulnerabilities.

## Unified-Zig-API Stack

The estate standard for all Zig-edge service boundaries is the **unified-zig-api
stack** documented in `developer-ecosystem/UNIFIED-ZIG-API-STACK.adoc`. It provides
four vertically-stacked layers:

| Layer | Location | Description |
|-------|----------|-------------|
| Idris2 core (proven) | `verification-ecosystem/proven/` | 104 formally verified primitives, `%default total`, zero `believe_me` |
| Idris2 ABI | `developer-ecosystem/zig-api/src/ZigApi/ABI/` | Dependent-type proofs of the C ABI surface |
| Zig runtime | `developer-ecosystem/zig-api/ffi/zig/src/` | `uapi_*` symbol set; gnosis HTTP server + connector pool |
| C adaptor | `developer-ecosystem/zig-api/generated/abi/zig_api.h` | Auto-generated; never edit by hand |

**BoJ alignment status (2026-04-17):** BoJ does **not yet** consume `libzig_api`
in code. The cartridge ABI + FFI layers (Idris2 + Zig) are BoJ-local today.
Full alignment — calling `uapi_gnosis_*` from the BoJ adapter and linking
`libzig_api.so` — is tracked in ADR-0002 as future work. First estate consumers
wired on 2026-04-17: lol-gateway, aerie, emergency-button/emergency-room.

The `uapi_gnosis_set_handler` pattern (single-port handler dispatch) is in flight
as of this version; BoJ will adopt it once stabilised upstream.

**Open question:** When BoJ adopts `uapi_gnosis_*`, the per-port V-legacy adapter
pattern (ports 7700/7701/7702) will consolidate to a single-port gnosis server.
Port assignments are documented in `docs/API-CONTRACT.md` and are stable until
a major version bump. Track progress in ADR-0002.

See `developer-ecosystem/UNIFIED-ZIG-API-STACK.adoc` for the canonical wiring guide.

## License

PMPL-1.0-or-later. The license's provenance requirements (crypto signatures, emotional lineage) align directly with the hash attestation model — the legal framework and the technical framework say the same thing.
