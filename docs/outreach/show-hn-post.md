<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Show HN submission draft for BoJ Server -->
<!-- Last updated: 2026-03-10 -->

# Show HN Draft

**Title:** Show HN: BoJ -- One MCP server for 18 capability domains, formally verified

---

**Body:**

I had three Claude instances, a Cursor session, and about twenty MCP/LSP/DAP servers running. My desktop froze. That was the moment I realised the problem wasn't any individual server -- it was the combinatoric explosion of them.

BoJ (Bundle of Joy) is a single server that covers 18 capability domains -- database, containers, git, secrets, queues, IaC, observability, static sites, proofs, fleet management, neurosymbolic AI, agent orchestration, cloud, Kubernetes, LSP, DAP, BSP, and feedback -- through one binary. Each domain is a "cartridge" with a formally verified interface (Idris2 dependent types prove the safety gate at compile time), a Zig FFI layer for native execution, and a V-lang adapter that exposes REST + gRPC + GraphQL on three ports. The whole thing is ~18MB, thread-safe, zero Python, zero JavaScript runtime.

The architecture is a 2D matrix: protocols on one axis, domains on the other. Instead of N separate servers, you get one catalogue where AI agents read a menu and mount what they need. Federation is built in -- community nodes discover each other via QUIC gossip with hash attestation, so you can self-host a node and join the network without any central coordination.

This is a community project. I make nothing from it. The code is PMPL-licensed. I'm looking for people to try it, host nodes, and tell me what breaks. 307 tests pass but the whole thing is still Alpha -- it needs real users doing real things.

Repo: https://github.com/hyperpolymath/boj-server
Getting started: https://github.com/hyperpolymath/boj-server/blob/main/docs/GETTING-STARTED.md

I built this to learn from it, and I learn most from other people using it.
