<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Blog post draft for dev.to / Hashnode -->
<!-- Last updated: 2026-03-24 -->

# Why I Built a Server Catalogue with Three Languages and Zero Python

## The moment my desktop froze

I had three Claude instances running. One Cursor session. About twenty MCP servers, a handful of LSP servers, two DAP servers, and a build server. Each one was a separate process, each with its own configuration, its own port, its own dependencies. My system had 47 open sockets and was using 14GB of RAM just for developer tooling.

Then my desktop froze.

I sat there, staring at a black screen, and thought: *this is not a tooling problem. This is a combinatorics problem.*

## The problem nobody talks about

Developer protocols are multiplying. MCP (Model Context Protocol) lets AI talk to tools. LSP handles language intelligence. DAP does debugging. BSP manages builds. Each protocol is useful. Each tool that speaks a protocol is useful. But the product of protocols times tools times AI agents is an explosion.

If you have 5 AI tools and 12 capability domains, you don't need 12 servers. You need 12 servers *per protocol*. And if each server is a separate Python process with its own virtualenv and its own dependency tree, you're running a small data centre on your laptop.

The industry response has been to build *more* servers. One MCP server for databases. One for containers. One for Kubernetes. One for Git. Each well-crafted, each standalone, each adding another process to your system tray.

I went a different way.

## The insight: it's a matrix

The capability landscape isn't a list. It's a 2D matrix:

```
              MCP    LSP    DAP    BSP    gRPC   REST
           +------+------+------+------+------+------+
Database   |  ##  |      |      |      |  ##  |  ##  |
Container  |  ##  |      |      |      |  ##  |  ##  |
Git/VCS    |  ##  |      |      |      |  ##  |  ##  |
Secrets    |  ##  |      |      |      |  ##  |  ##  |
Queues     |  ##  |      |      |      |  ##  |  ##  |
IaC        |  ##  |      |      |      |  ##  |  ##  |
Observe    |  ##  |      |      |      |  ##  |  ##  |
SSG        |  ##  |      |      |      |  ##  |  ##  |
Proof      |  ##  |      |      |      |  ##  |  ##  |
Fleet      |  ##  |      |      |  ##  |  ##  |  ##  |
NeSy       |  ##  |  ##  |      |      |  ##  |  ##  |
Agent      |  ##  |      |      |      |  ##  |  ##  |
Cloud      |  ##  |      |      |      |  ##  |  ##  |
K8s        |  ##  |      |      |      |  ##  |  ##  |
LSP        |  ##  |  ##  |      |      |  ##  |  ##  |
DAP        |  ##  |      |  ##  |      |  ##  |  ##  |
BSP        |  ##  |      |      |  ##  |  ##  |  ##  |
Feedback   |  ##  |      |      |      |  ##  |  ##  |
           +------+------+------+------+------+------+
```

Columns are protocols (how you talk). Rows are domains (what it does). Each filled cell is a **cartridge** -- a formally verified, swappable capability module. One server. One binary. 53 domains. Multiple protocols.

That's BoJ: the **Bundle of Joy** server.

## Why three languages (and why they're not the ones you expect)

The typical developer server is Python or TypeScript. BoJ uses none of those. Instead, every cartridge has three layers:

| Layer | Language | Job |
|-------|----------|-----|
| ABI | Idris2 | Prove the interface is correct |
| FFI | Zig | Execute it natively |
| Adapter | Elixir | Serve it over the network |

**Why Idris2?** Because it has dependent types. Not "type-safe" in the TypeScript sense. Actually provably correct at compile time. The core safety gate is a type called `IsUnbreakable` -- it's a mathematical proof that only cartridges in the `Ready` state can be activated. The type checker enforces this, not a runtime check, not a unit test. If the proof doesn't hold, the code doesn't compile.

```idris
-- Simplified: the safety gate
data IsUnbreakable : CartridgeState -> Type where
  MkUnbreakable : IsUnbreakable Ready

mount : (c : Cartridge) -> {auto prf : IsUnbreakable (state c)} -> IO ()
```

You literally cannot call `mount` on a cartridge that isn't `Ready`. The type system makes it impossible.

**Why Zig?** Because it produces C-ABI-compatible shared libraries with zero runtime dependencies. Each cartridge compiles to a `.so` file. The Zig layer bridges Idris2's proofs with actual system calls -- file I/O, networking, database connections. Cross-compilation is built in, which matters when community members run nodes on ARM, x86, or whatever they have.

**Why Elixir?** Because one Elixir codebase on the BEAM (Plug/Cowboy) exposes all three API styles (REST + gRPC + GraphQL) on dedicated ports, with the fault-tolerance and concurrency the BEAM is known for. One runtime, three protocols, no code generation step.

The result: a compact binary. 219 Zig tests + 8 integration tests + 32 seam checks. Thread-safe (every FFI entry point serialises on a per-module mutex). No virtualenvs, no node_modules, no pip install.

## How it works in practice

Start the server:

```bash
git clone https://github.com/hyperpolymath/boj-server.git
cd boj-server
cd ffi/zig && zig build && cd ../..
cd elixir && mix deps.get && mix run --no-halt
```

Three ports open:

```
REST:    http://localhost:7700
gRPC:    http://localhost:7701
GraphQL: http://localhost:7702
```

Check what's available:

```bash
curl http://localhost:7700/menu
```

Mount a cartridge:

```bash
curl -X POST http://localhost:7700/cartridges/database-mcp/load
```

Use it:

```bash
curl http://localhost:7700/cartridges/database-mcp/invoke \
  -X POST -H 'Content-Type: application/json' \
  -d '{"tool":"status","args":""}'
```

Or skip HTTP entirely and use MCP mode for AI tools:

```bash
./boj-server --mcp
```

This gives you a JSON-RPC 2.0 stdio server. All 53 cartridges appear as MCP tools. Add it to your MCP client config and your AI sees one server with 53 capabilities instead of 53 separate servers.

## Federation: the community IS the hosting

I don't have a hosting budget. I'm a solo developer. But I do have an idea: what if the community *is* the infrastructure?

BoJ includes a federation system called **Umoja** (Swahili for "unity"). Any community member can run a node:

1. Pull the container image (Chainguard base, Podman -- never Docker)
2. Run it
3. Your node joins the network via IPv6 gossip protocol
4. Requests route to healthy nodes automatically

The trust model is hash attestation. Every BoJ binary has a SHA-256 hash. Your node proves its binary matches the canonical build. If someone modifies their binary, they're excluded from the community network -- but they can still run it locally. Non-punitive. We don't brick your installation. We just don't vouch for it.

The gossip protocol is Byzantine fault tolerant. Nodes exchange peer lists, stale nodes get deprioritised, load-aware routing sends requests to nodes under 80% capacity. The federation transport uses QUIC with X25519 key exchange and ChaCha20-Poly1305 encryption, falling back to plain UDP when QUIC isn't available.

Four seed nodes across four continents from day one. No cloud bill. Just people running software on computers they already own.

## The HAT concept: don't throw away your tools

I want to address something directly: BoJ is not trying to replace your database MCP server or your Kubernetes CLI. Those tools are good. People built them with care.

What BoJ does is give them a uniform shopfront. Think of it like a Hardware store with an Attached Toolshed -- a **HAT**. You don't throw away your hammer when you buy a toolbox. You put it in the toolbox so you can find it.

The third axis of the matrix (the one I haven't mentioned yet) is the **backend** axis. Each cartridge has a backend field -- by default it's `"universal"`, but community extensions can specialise it. Want a `database-mcp` cartridge that talks specifically to PostgreSQL? That's a backend variant. The core cartridge defines the interface (via Idris2 proofs); the backend variant implements it for a specific provider.

The community submission system (called "Ayo", meaning "joy" in Yoruba) lets anyone submit a cartridge variant. It goes through a review state machine (`submitted -> under_review -> approved`), and approved cartridges appear in the community tier of the Teranga menu.

## The honest assessment

BoJ is Alpha. Grade D on most cartridges. Here's what's real:

- 53 cartridges, all with ABI + FFI + adapter layers, all compiling to `.so` files
- 219 Zig tests, 8 integration tests, 32 seam checks — all passing
- Thread-safety hardening across all 9 core + 53 cartridge FFI modules (all mutex-protected)
- MCP stdio bridge working (JSON-RPC 2.0, all 53 cartridges as tools)
- Umoja federation with real QUIC+UDP networking (22 federation tests)
- Zero `believe_me` in production code (Idris2's escape hatch -- we don't use it)
- Security audit by panic-attack scanner: 1 expected weak point (QUIC 0-RTT replay window, mitigated at app layer), 0 critical vulnerabilities

Here's what's not done:

- No real users besides me
- Seed nodes aren't deployed to actual infrastructure yet
- The Teranga menu runtime is 30% complete (the spec exists, the runtime doesn't)
- Most cartridges are Grade D (they work, but they haven't been tested by diverse external users)
- No domain name yet for the federation network

This isn't a product launch. This is a "come look at what I built and tell me what's wrong with it" post.

## Try it, host a node, or just tell me what you think

Install: `npm install -g @hyperpolymath/boj-server` or `nix build github:hyperpolymath/boj-server`

The repo is at [github.com/hyperpolymath/boj-server](https://github.com/hyperpolymath/boj-server). The quickstart guide is [docs/QUICKSTART.md](https://github.com/hyperpolymath/boj-server/blob/main/docs/QUICKSTART.md).

What I'm looking for:

- **Try it locally** -- clone, build, run `curl http://localhost:7700/matrix` and tell me if the experience makes sense
- **Host a node** -- if you have a machine that's on during the day, you can join the Umoja network. See `container/` in the repo
- **Build on it** -- the extensibility system lets you add backend variants without touching core code. See `docs/EXTENSIBILITY.md`
- **Tell me what breaks** -- feedback-mcp is literally a cartridge that collects feedback. BoJ dogfoods itself

This is a community project. I make nothing from it. The license (MPL-2.0) ensures the code stays open and provenance-tracked.

I built this to learn from it, and I learn most from other people using it.

---

*Jonathan D.A. Jewell builds developer tools and formal verification systems. BoJ is part of the hyperpolymath ecosystem of open-source projects.*
