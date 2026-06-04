<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Show HN submission draft for BoJ Server -->
<!-- Last updated: 2026-04-12 -->

# Show HN Draft

**Title:** Show HN: BoJ – One MCP server, 99 capability cartridges, zero Python

---

**Body:**

I had three Claude instances, a Cursor session, and about twenty MCP/LSP/DAP servers running. My desktop froze. That was the moment I realised the problem wasn't any individual server — it was the combinatoric explosion of them.

BoJ (Bundle of Joy) is a single MCP server that covers 99 capability domains through swappable cartridges. Database, containers, git, secrets, queues, IaC, observability, static sites, proofs, fleet management, neurosymbolic AI, agent orchestration, cloud, Kubernetes, LSP, DAP, BSP, feedback, and more. Each cartridge has a formally verified interface (Idris2 dependent types prove the safety gate at compile time), a Zig FFI layer for native execution, and a unified adapter that exposes REST + gRPC + GraphQL + SSE on four ports. Five safety modules (SafeHTTP, SafePromptInjection, SafeCORS, SafeAPIKey, SafeWebSocket) guard the boundary.

The architecture is a 2D matrix: protocols on one axis, domains on the other. Instead of N separate servers, you get one catalogue where AI agents read a menu and mount what they need. Federation is built in — community nodes discover each other via gossip with hash attestation, so you can self-host a node and join the network without any central coordination.

Install: `deno install -g npm:@hyperpolymath/boj-server` or `brew install hyperpolymath/tap/boj-server`

The whole thing is Alpha — it needs real users doing real things.

Repo: https://github.com/hyperpolymath/boj-server
Quickstart: https://github.com/hyperpolymath/boj-server/blob/main/docs/quickstarts/USER.adoc

This is a community project. I make nothing from it. The code is PMPL-licensed (MPL-2.0 fallback). I built this to learn from it, and I learn most from other people using it.
