<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->

# BoJ Server -- the "Bundle of Joy" Server

One MCP server that gives any AI assistant access to your databases, containers, git repos, secrets, and more -- instead of installing seven separate tools.
A genuine 'bundle of joy'.

<a href="https://glama.ai/mcp/servers/hyperpolymath/boj-server">
  <img width="380" height="200" src="https://glama.ai/mcp/servers/hyperpolymath/boj-server/badge" alt="BoJ MCP Server on Glama" />
</a>
<a href="https://www.bestpractices.dev/projects/12164">
  <img src="https://www.bestpractices.dev/projects/12164/badge" alt="OpenSSF Best Practices passing (115%)" />
</a>

## 🏰 Dual-Track Architecture

BoJ Server provides two distinct ways to interact with cartridges, catering to different needs for simplicity and scale.

### **Class 1: Simple Track (Canonical)**
- **Focus:** Simplicity, local-first, zero-infrastructure.
- **Workflow:** Repositories use standard GitHub Actions (`curl` triggers) to talk to the server.
- **Implementation:** Each cartridge is self-contained with its own adapters.
- **Best for:** Most users, quick setups, and easy debugging.

### **Class 2: Orchestrator Track (Advanced)**
- **Focus:** Unified transport, high-performance, massive scale.
- **Workflow:** Uses secure Webhooks (HMAC-SHA256) and unified real-time gateways (MQTT/WebSockets).
- **Implementation:** Core-level generic handlers located in `adapter/v/src/class_2_orchestrator/`.
- **Best for:** Production environments, IoT integration, and multi-agent orchestration.

---

## Quick Start

**1. Clone and build**

```bash
git clone https://github.com/hyperpolymath/boj-server
cd boj-server
cd ffi/zig && zig build
```

**2. Start the server**

```bash
cd boj-server && deno run --allow-net --allow-env mcp-bridge/main.js
```

**3. Connect your AI assistant**

Add to your Claude Code MCP config (`~/.config/claude/mcp_servers.json`):

```json
{
  "boj-server": {
    "command": "node",
    "args": ["/path/to/boj-server/mcp-bridge/main.js"],
    "env": { "BOJ_URL": "http://localhost:7700" }
  }
}
```

> HTTP/SSE remote transport for ChatGPT, Gemini, and other clients is coming soon.

## What Can It Do?

BoJ organises capabilities into **cartridges** (pluggable modules), each covering a domain. Here is what is available today:

| Domain | Cartridge | Example |
|--------|-----------|---------|
| Database | database-mcp | "Query my PostgreSQL database for all users created this week" |
| Containers | container-mcp | "List running containers and restart the web server" |
| Git | git-mcp | "Show me the diff between main and this branch across all three forges" |
| Secrets | secrets-mcp | "Rotate the API key stored in Vault and update the deployment" |
| Observability | observe-mcp | "Show me error rates from the last hour and correlate with recent deploys" |
| Cloud | cloud-mcp | "Spin up a staging instance on my cloud provider" |
| Kubernetes | k8s-mcp | "Scale the worker deployment to 5 replicas" |
| Queues | queues-mcp | "Check the dead-letter queue depth and replay failed messages" |
| Infrastructure | iac-mcp | "Plan the Terraform changes for the new VPC" |
| Static Sites | ssg-mcp | "Build and preview the documentation site" |
| Proof Assistants | proof-mcp | "Type-check the Idris2 module and show any holes" |
| Language Servers | lsp-mcp | "Get completions and diagnostics for this file" |
| Debugging | dap-mcp | "Set a breakpoint at line 42 and inspect the variable" |
| Build Servers | bsp-mcp | "Run the build and report compile errors" |
| Bot Fleet | fleet-mcp | "Run the security scan bots across all repositories" |
| Neurosymbolic | nesy-mcp | "Classify this input using the symbolic reasoning pipeline" |
| Agents | agent-mcp | "Dispatch an OODA-loop agent to investigate the incident" |

## Why BoJ Instead of Separate MCP Servers?

**One connection, not seventeen.** Your AI assistant connects to one server and gets access to all domains through a single menu.

**Lower memory footprint.** One native process instead of 7+ separate `npm exec` processes each consuming 200-300 MB of RAM.

**Verified state machines.** Each cartridge's lifecycle (connect, query, disconnect) is modelled as a state machine with formal proofs that prevent invalid transitions. This means your AI cannot, for example, issue a query on a closed database connection.

**Federation-ready.** BoJ nodes can form a peer-to-peer network (Umoja federation) for production-scale distributed hosting. Community nodes volunteer compute, with cryptographic hash attestation ensuring integrity.

## Current Status

**Grade D (Alpha)** -- usable for experimentation, not yet production-hardened.

| What | Status |
|------|--------|
| Cartridges built | 17 of 17, all with compiled .so files |
| Tests passing | 307 |
| MCP bridge | Working (stdio) |
| REST / gRPC / GraphQL | Adapter compiles and routes |
| Federation (Umoja) | Real UDP gossip with hash attestation |
| Remote transport (HTTP/SSE) | Not yet |
| External dogfooding | Not yet |

See [docs/READINESS.md](docs/READINESS.md) for the full component-by-component assessment.

## Architecture (For Contributors)

BoJ uses Idris2 for interface proofs (zero `believe_me`), Zig for the C-compatible FFI layer, V-lang for the REST/gRPC/GraphQL adapter, and JavaScript for the MCP bridge. If that sounds like a lot of languages, it is -- each was chosen for a specific guarantee. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the rationale and contributor guide.
