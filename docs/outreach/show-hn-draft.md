<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Show HN: BoJ — 99-cartridge MCP server with formal proofs (Idris2 + Zig)

BoJ (Bundle of Joy) is an MCP server that bundles 99 tool cartridges — each with a formally verified ABI (Idris2), a C-compatible FFI (Zig), and a unified adapter exposing REST, gRPC, GraphQL, and SSE on four ports.

What makes it different:

- **99 cartridges** covering cloud (Cloudflare, Vercel), comms (Gmail, calendar), GitHub/GitLab, databases, containers, security (DNS Shield, container hash monitoring, licence-chain provenance via pmpl-mcp), browsers, and more
- **Formal safety proofs** — every cartridge has an Idris2 ABI module with dependent types and zero `believe_me` postulates. The type system prevents entire classes of runtime errors
- **Zero Python, zero TypeScript** — built with Zig (FFI), Idris2 (proofs), and a ReScript UI. No npm, no pip, no node_modules
- **Glama AAA grade** — Security A, License A, Quality A
- **Federation-ready** — Umoja gossip protocol with QUIC transport, hash attestation, 4 seed node configs

The architecture follows the "ABI/FFI/API triple" pattern: Idris2 proves the interface correct at compile time, Zig implements it with C ABI compatibility, and the adapter provides the user-facing API. Adding a new cartridge means writing ~600 lines across 3 files.

Running locally:

```
git clone https://github.com/hyperpolymath/boj-server
cd boj-server && just build && just serve
# REST :7700 | gRPC :7701 | GraphQL :7702 | SSE :7703
```

Quickstart: https://github.com/hyperpolymath/boj-server/blob/main/docs/quickstarts/USER.adoc

MPL-2.0 license (MPL-2.0 legal fallback; OSI submission pending).

GitHub: https://github.com/hyperpolymath/boj-server
