# Bundle of Joy (BoJ) Server

Unified server capability catalogue with formally verified cartridges, distributed community hosting, and the Teranga menu system.

> **AI-Assisted Install:** Just tell any AI assistant:
> `Set up Bundle of Joy Server from https://github.com/hyperpolymath/boj-server`
> The AI reads this repo, asks you a few questions, and handles everything.

## What is this?

BoJ solves the **combinatoric explosion of developer server protocols**. Instead of hunting across dozens of MCP, LSP, DAP, and other servers, AI goes to ONE place — the Teranga menu — and orders what it needs.

The server is **distributed**: community nodes volunteer compute time (like Tor/IPFS), with cryptographic hash attestation ensuring integrity. No central hosting required.

## The 2D Capability Matrix

Capabilities are organised as a 2D matrix:

- **Columns** = protocol types (MCP, LSP, DAP, BSP, NeSy, Agentic, Fleet, gRPC, REST)
- **Rows** = capability domains (Cloud, Container, Database, K8s, Git, Secrets, Queues, IaC, Observe, SSG, Proof, Fleet, NeSy)
- **Cells** = cartridges (formally verified, swappable capability modules)

Each cartridge follows the **three-layer stack**:

| Layer | Language | Purpose |
|-------|----------|---------|
| **ABI** | Idris2 | Formal proofs, `%default total`, zero `believe_me` |
| **FFI** | Zig | C-compatible native execution, zero runtime deps |
| **Adapter** | V-lang | Triple API (REST + gRPC + GraphQL) |

## The Teranga Menu

The menu has three tiers:

- **Teranga (Core)**: Cartridges maintained by the project
- **Shield**: Privacy and security (SDP, DoQ/DoH, oDNS)
- **Ayo (Community)**: Community-contributed cartridges

AI agents act as the "Maître D'" — presenting the menu to users as honoured guests.

See: `.machine_readable/servers/menu.a2ml`

## Quick Start

```bash
# Clone and enter
git clone https://github.com/hyperpolymath/boj-server
cd boj-server

# Type-check the Idris2 ABI
cd src/abi && idris2 --build boj.ipkg

# Build the Zig FFI
cd ../../ffi/zig && zig build

# Run tests
cd ffi/zig && zig build test
```<a href="https://glama.ai/mcp/servers/hyperpolymath/boj-server">
  <img width="380" height="200" src="https://glama.ai/mcp/servers/hyperpolymath/boj-server/badge" />
</a>

## Distributed Hosting (Umoja Network)

BoJ servers are community-hosted:

- Pull the container from the Stapeln supply chain
- Run it locally (Podman, Chainguard base)
- Your node appears in the Umoja network via gossip protocol
- Hash attestation ensures integrity — tampered nodes are excluded from the community network but can still run locally

See: `docs/FEDERATION.md`

## Contributing Cartridges

Build a cartridge that passes the `IsUnbreakable` proof and it goes in the Ayo menu with your name honoured.

See: `docs/DEVELOPERS.md`

## Cultural Terminology

We use terms from Wolof (*Teranga* — hospitality), Swahili (*Umoja* — unity), and Yoruba (*Ayo* — joy) to align our architecture with global values.

See: `docs/CULTURAL-RESPECT.md`

## License

PMPL-1.0-or-later (Palimpsest License). The license's provenance requirements (crypto signatures, emotional lineage) align directly with the hash attestation model.

## Project Status

**Grade A (Production)** — 18 cartridges, 307 tests passing, thread-safe FFI (mutex-hardened), panic-attack validated. See `READINESS.md` for the full CRG assessment and `.machine_readable/STATE.a2ml` for milestone progress.

## A Community Project

This is a community project. Nobody makes money from it. It exists because the problem (too many servers, too much fragmentation) needed solving, and the solution needed building.

**What would help most right now:**

- **Host a node** — Even for a few hours a week. Pull the container, let it gossip. Every node strengthens the network. See `docs/OPERATOR-QUICKSTART.md`.
- **Try it out** — Use it via MCP, REST, or gRPC. Break things. Tell me what's confusing, what's missing, what doesn't work.
- **Build on it** — Write a cartridge, create an extension, wire it to your own tools. The third axis is wide open.
- **Give feedback** — Comments, issues, PRs, emails, carrier pigeons. All welcome.

A huge thank you to anyone who takes the time to look at this. Even a quick glance and an honest opinion helps enormously. I built this to learn from it, and I learn most from other people using it.

Contact: `j.d.a.jewell@open.ac.uk` | GitHub: [hyperpolymath](https://github.com/hyperpolymath) | Issues: [boj-server/issues](https://github.com/hyperpolymath/boj-server/issues)
