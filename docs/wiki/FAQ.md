<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Frequently Asked Questions

## What does "Bundle of Joy" mean?

**BoJ stands for Bundle of Joy.** It is NOT "Bureau of Justice" or any government agency. The name reflects the project's philosophy: each cartridge is a small, self-contained "bundle" of capability, and the Ayo community tier literally means "joy" in Yoruba. The Teranga menu system (from the Wolof word for hospitality) treats AI agents as honoured guests.

## Why three languages?

The three-layer stack (Idris2, Zig, V-lang) exists because each language solves a different problem exceptionally well:

| Layer | Language | Why this one? |
|-------|----------|---------------|
| **ABI** | Idris2 | Dependent types prove interface correctness at compile-time. The `IsUnbreakable` proof type mathematically guarantees that only `Ready` cartridges can be activated. No other language provides this level of formal verification with practical usability. |
| **FFI** | Zig | Native C ABI compatibility with zero runtime overhead. Built-in cross-compilation for varied community node hardware. Memory-safe by default. |
| **Adapter** | V-lang | Exposes REST + gRPC + GraphQL from a single codebase. One port per protocol, minimal boilerplate. |

The compilation pipeline is: Idris2 defines the contract (what CAN happen), Zig implements it (what DOES happen), V-lang exposes it (how you REACH it).

## How does the capability matrix work?

The matrix is a 2D grid:

- **Rows** = capability domains (Database, Container, Cloud, K8s, Git, Secrets, Queues, IaC, Observe, SSG, Proof, Fleet, NeSy, Agent, LSP, DAP, BSP, Feedback)
- **Columns** = protocol types (MCP, LSP, DAP, BSP, NeSy, Agentic, Fleet, gRPC, REST)
- **Cells** = cartridges

The matrix is intentionally **sparse** -- not every cell needs to be filled. Currently 18 cartridges fill the most useful cells. Each cartridge occupies one or more cells (e.g., `database-mcp` fills the Database row across MCP, gRPC, and REST columns).

There is also an optional **third axis** (depth) for backend/provider specialisation. Core cartridges use `backend="universal"`. Community extensions can specialise, e.g., `database-mcp-pg` for PostgreSQL-specific operations. See [`docs/EXTENSIBILITY.md`](../EXTENSIBILITY.md).

## How does federation work?

The **Umoja** federation (Swahili for "Unity") is a distributed network of community-hosted BoJ nodes, similar to Tor or IPFS.

**For users:** Your AI reads the Teranga menu. If the local BoJ has the cartridge, it's served locally. If not, the request is transparently routed to a community node that has it.

**For operators:** Pull the BoJ container, run it with Podman, and your node joins the network via the gossip protocol. No central registry required.

**Trust model:** Hash attestation. Every BoJ binary has a SHA-256 hash. Community nodes prove their binary matches the canonical build. Modified binaries are excluded from the network but can still run locally. This is non-punitive.

**Transport:** QUIC-first with UDP fallback. Key exchange uses X25519 ECDH, encryption uses ChaCha20-Poly1305 AEAD. The federation runs on UDP port 9999 by default.

**Gossip protocol:** Nodes exchange peer lists periodically. New nodes propagate through the network. Stale nodes (not seen for >1 hour) are deprioritised. The protocol is Byzantine fault tolerant.

## How secure is it?

BoJ has been tested with **panic-attack** (the project's security assail tool):

- **1 weak point found**: QUIC crypto (expected -- QUIC implementations are complex)
- **0 critical Zig vulnerabilities**
- **0 cross-language vulnerabilities** (ABI/FFI boundary is clean)

Security layers include:

| Layer | What it does |
|-------|-------------|
| **IsUnbreakable proof** | Type-level guarantee that only verified cartridges can activate |
| **Hash attestation** | Binary integrity verification for all federation nodes |
| **Auto-SDP** | Software Defined Perimeter -- zero exposed ports until authenticated |
| **QUIC encryption** | X25519 + ChaCha20-Poly1305 for all federation traffic |
| **DoQ/DoH** | Encrypted DNS resolution |
| **oDNS relay** | Oblivious DNS for maximum privacy (optional) |
| **Seccomp profile** | Restricted system calls in container |
| **Read-only rootfs** | Container filesystem cannot be modified at runtime |
| **Chainguard base** | Minimal attack surface container images |
| **Thread-safety** | All 55 mutable globals protected by `std.Thread.Mutex` |

See [`docs/THREAT-MODEL.md`](../THREAT-MODEL.md) for the full STRIDE analysis.

## Can I use my existing tools with BoJ?

Yes, through the **HAT** (Hyperpolymath Adapter Toolkit) concept.

BoJ does not replace your existing tools -- it **unifies access** to them. The protocol bridge cartridges (`lsp-mcp`, `dap-mcp`, `bsp-mcp`) let you access LSP, DAP, and BSP servers through the BoJ interface. The adapter layer (V-lang) exposes everything as REST + gRPC + GraphQL, so any HTTP client works.

For AI tools specifically, BoJ speaks **MCP natively** via JSON-RPC 2.0 over stdio. Add it to `claude_desktop_config.json` or any MCP-compatible client and all 18 cartridges appear as MCP tools.

If your tool isn't covered by an existing cartridge, you can create a **community extension** (third-axis backend specialisation) without modifying BoJ's core code. See the [Developer Guide](Developer-Guide) for details.

## What is the Teranga menu?

The Teranga menu is the public catalogue of available capabilities, stored at `.machine_readable/servers/menu.a2ml`. It has three tiers:

| Tier | Name | Meaning | What's in it |
|------|------|---------|-------------|
| 1 | **Teranga** | Hospitality (Wolof) | Core infrastructure cartridges maintained by the project |
| 2 | **Shield** | -- | Privacy and security cartridges (SDP, DoQ/DoH, oDNS) |
| 3 | **Ayo** | Joy (Yoruba) | Community-contributed cartridges |

AI agents act as the "Maitre D'" -- presenting the menu to users as honoured guests, taking their order (via the Order-Ticket Protocol), and having the kitchen prepare it.

## What is the Order-Ticket Protocol?

The order-ticket protocol is how AI agents request capabilities:

1. AI reads the Teranga menu
2. AI writes an order ticket (`order-ticket.scm` or JSON via REST)
3. BoJ validates the order against the catalogue (checks `IsUnbreakable`)
4. BoJ mounts the requested cartridges via Zig FFI
5. V-lang adapter exposes mounted cartridges as REST + gRPC + GraphQL
6. AI receives confirmation with endpoints

## How does BoJ relate to polystack?

BoJ **supersedes** polystack. The 13 poly-* MCP domain components from polystack are now covered by BoJ's 18 cartridges. Polystack has been archived as of 2026-03-08.

## What is VeriSimDB?

VeriSimDB is a separate database project that BoJ uses as its **backing store** for cartridge state. The `database-mcp` cartridge provides end-to-end VeriSimDB operations (octad CRUD, VQL queries, drift detection). BoJ dogfoods VeriSimDB -- the project uses its own database cartridge to manage its own state.

## What are seam checks?

Seam checks are panic-attack-style integration contract tests that validate all FFI boundaries. They verify that enum encodings, safety gates, hash attestation, backend defaults, JSON fields, and protocol ranges are all consistent between the Idris2 ABI and the Zig FFI. Run them with `zig build seams`. A clean run produces a "silent signature" -- 13 checks pass with nothing to report.

## How do I contribute?

See the [Developer Guide](Developer-Guide) for building from source and adding cartridges. See [`CONTRIBUTING.md`](../../CONTRIBUTING.md) for the full contribution process. Community cartridges go in the Ayo tier -- "ayo" means "joy" in Yoruba, so contributing a verified cartridge means sharing joy with the community.
