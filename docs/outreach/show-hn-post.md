<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Show HN submission draft for BoJ Server -->
<!-- Last updated: 2026-03-24 -->

# Show HN Draft

**Title:** Show HN: BoJ -- One MCP server with 53 formally verified cartridges, zero Python

---

**Body:**

I had three Claude instances, a Cursor session, and about twenty MCP/LSP/DAP servers running. My desktop froze. That was the moment I realised the problem wasn't any individual server -- it was the combinatoric explosion of them.

BoJ (Bundle of Joy) is a single MCP server that covers 53 capability domains through swappable cartridges. Database, containers, git, secrets, queues, IaC, observability, static sites, proofs, fleet management, neurosymbolic AI, agent orchestration, cloud, Kubernetes, LSP, DAP, BSP, feedback, and more. Each cartridge has a formally verified interface (Idris2 dependent types prove the safety gate at compile time), a Zig FFI layer for native execution, and a V-lang adapter that exposes REST + gRPC + GraphQL on three ports. Thread-safe, zero Python, zero JavaScript runtime.

The architecture is a 2D matrix: protocols on one axis, domains on the other. Instead of N separate servers, you get one catalogue where AI agents read a menu and mount what they need. Federation is built in -- community nodes discover each other via QUIC gossip with hash attestation, so you can self-host a node and join the network without any central coordination.

Install: `npm install -g @hyperpolymath/boj-server` or `nix build github:hyperpolymath/boj-server`

219 Zig tests pass, 8/8 integration tests pass, 32 seam checks pass. The whole thing is Alpha -- it needs real users doing real things.

Repo: https://github.com/hyperpolymath/boj-server
Quickstart: https://github.com/hyperpolymath/boj-server/blob/main/docs/QUICKSTART.md
Glama: https://glama.ai/mcp/servers/hyperpolymath/boj-server

This is a community project. I make nothing from it. The code is PMPL-licensed. I built this to learn from it, and I learn most from other people using it.
