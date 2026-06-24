<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# 13. Streamable HTTP transport — Workers + remote browser-client deployment

Date: 2026-05-20

## Status

Proposed (RFC — implementation tracked in epic #87 item 14)

## Context

BoJ today speaks MCP over **stdio only**. The bridge process is launched as a child by an MCP client (Claude Code, Claude Desktop, Cursor, etc.), reads JSON-RPC from stdin, writes responses to stdout. This works perfectly for client-launched local deployments.

It does not work for:

- **Cloudflare Workers** — Workers have no stdio; they're request-response only with strict CPU/duration limits. The Workers MCP pattern (Cloudflare's own MCP servers + the Workers MCP guide) uses HTTP transport.
- **Remote browser-based agents** — A web app that wants to use BoJ tools cannot spawn a subprocess; it has to call BoJ over HTTP.
- **Federated multi-tenant deployments** — one BoJ instance serving multiple clients on different machines. Each client wants its own session over the network, not stdio.
- **Long-lived sessions across stdio reconnects** — when an MCP client crashes and restarts, stdio state is lost. HTTP transport with session IDs lets the client resume.

The MCP specification added **Streamable HTTP transport** (also called HTTP+SSE) alongside stdio in 2024. The current bridge doesn't implement it. This is the gap.

JSR runtime-compatibility surfaced this directly: the user can't tick "Browsers" or "Cloudflare Workers" because the bridge legitimately doesn't run there. Item 14 is the right framing of that gap — not "make stdio work in a browser" (architecturally wrong) but "add an HTTP transport for the contexts where stdio doesn't work."

## Decision

Implement **Streamable HTTP transport** alongside stdio. Both transports coexist; the binary chooses at startup based on env. No existing stdio clients break.

### Transport mode selection

```
BOJ_TRANSPORT=stdio   # current behaviour, default
BOJ_TRANSPORT=http    # new — listen on BOJ_HTTP_PORT (default 7780)
BOJ_TRANSPORT=both    # listen on both simultaneously
```

### HTTP endpoint shape

Two endpoints per the MCP spec:

```
POST /mcp                    — submit a JSON-RPC request, get response
GET  /mcp                    — open SSE stream for server-initiated notifications
```

Single endpoint design (per the latest spec revision); some earlier MCP HTTP implementations used `/mcp/sse` separately, but the spec consolidated.

Headers:
```
Mcp-Session-Id: <uuid>      — required on every request after initialize
Mcp-Protocol-Version: 2024-11-05
```

The session ID is server-issued on `initialize`; client sends it on every subsequent request. Allows the server to maintain per-session state (rate-limit state, OTel trace context, in-flight quarantine entries) across requests in a stateless transport.

### Authorization

HTTP transport opens BoJ to the public internet (if so deployed), unlike stdio which is local-process-bound. Authorization is required, not optional.

Per ADR-0007 (trust-tier policy DSL), the bridge already routes through a PEP. HTTP transport adds an authentication layer in front of the PEP:

| Mode | Auth | When |
|---|---|---|
| `BOJ_HTTP_AUTH=none` | No auth | Loopback only (`127.0.0.1`); refuses non-loopback connections. Dev convenience. |
| `BOJ_HTTP_AUTH=bearer` | `Authorization: Bearer <token>` | Token list in `BOJ_HTTP_AUTH_TOKENS` (CSV) or `~/.boj/http-tokens.a2ml` (per-peer). |
| `BOJ_HTTP_AUTH=mtls` | Client cert verification | Production. Cert pool at `BOJ_HTTP_MTLS_CA`. |
| `BOJ_HTTP_AUTH=oidc` | OIDC token verification | Federated; verifies token against an issuer config. Defers to coord-mcp's DID model when federation is active (ADR-0010). |

Default: **`bearer` if HTTP transport is enabled and the listener is non-loopback**. The bridge refuses to start with `BOJ_HTTP_AUTH=none` on a non-loopback bind.

### Deployment targets enabled

| Target | Works? | Caveats |
|---|---|---|
| Single-process stdio (today) | ✅ unchanged | Nothing breaks |
| Single-process HTTP | ✅ new | Same bridge, listening on port |
| Docker / Podman container | ✅ new | Already trivial; just expose the port |
| Cloudflare Worker | ✅ new | With caveats: long-lived state requires Durable Objects; ~60% of tools (HTTP-API-based cartridges) work; local-only cartridges (browser-mcp, container-mcp, local-coord-mcp) don't |
| AWS Lambda / Vercel Edge | ⚠️ limited | Stateless functions can serve `POST /mcp` but can't hold SSE streams long-term |
| Browser-based agent web apps | ✅ new | Via `fetch` against a hosted BoJ instance |

### What does NOT change

- **stdio transport** — fully preserved; default mode unchanged
- **Cartridge architecture** — Idris2 ABI + Zig FFI + Deno/JS adapter triple
- **Tool surface** — same `tools/list`, `resources/list`, `prompts/list` outputs; HTTP just changes how requests arrive
- **Security gate** — `hardeningGate` runs identically on both transports
- **OTel span emission** — every HTTP request emits a span (same as stdio tools/call)

### Cartridge compatibility under HTTP

For deployments where BoJ runs HTTP-transport-only (e.g. Cloudflare Worker), some cartridges become non-functional:

| Cartridge category | HTTP-only? | Reason |
|---|---|---|
| GitHub/GitLab/Cloudflare/Vercel/etc. | ✅ Works | Pure HTTP API calls outbound |
| Hugging Face / ML / Semantic Scholar | ✅ Works | HTTP API |
| Search (new from item 8) | ✅ Works | HTTP API |
| Database cartridges (HTTP-API ones: Supabase, Neon, Turso) | ✅ Works | HTTP API |
| Database cartridges (TCP: PostgreSQL, Redis, MongoDB) | ⚠️ Workers-limited | Cloudflare Hyperdrive workaround |
| `browser-mcp` (Firefox via Marionette) | ❌ Local-only | Needs host browser |
| `container-mcp`, `k8s-mcp` | ❌ Local-only | Needs Podman/kubectl |
| `local-coord-mcp` | ❌ Local-only | Loopback bus (unless ADR-0010 federation lands) |
| `sandbox-mcp` (per ADR-0009, local backend) | ❌ Local-only | Process isolation requires host |
| `sandbox-mcp` (per ADR-0009, SaaS backends) | ✅ Works | Pure HTTP API |

A new `boj_capabilities` extension reports per-deployment which cartridges are actually available, so MCP clients don't try to invoke locally-impossible operations against a Workers-deployed BoJ.

## Consequences

### Positive

- **Three new deployment targets** unlocked: Workers, containers, browser-based agents
- **JSR runtime-compatibility honest** — Browsers + Workers can be ticked once item 14 lands, with documented cartridge compatibility caveats
- **Federation alignment** (ADR-0010) — cross-machine coord federation needs HTTPS transport anyway; this RFC's transport is reusable for the federation layer
- **Session state across reconnects** — long-lived MCP sessions survive client crashes
- **Same security model** — `hardeningGate` + policy DSL (ADR-0007) work identically on both transports
- **Webhook-inbound consolidation** (ADR-0011) — the existing Cowboy listener for webhooks can host the MCP HTTP endpoint too (single port, two paths: `/webhooks/*` and `/mcp`)
- **OTel spans for free** — instrumentation from item 13 / PR #91 applies to HTTP requests with no extra work
- **Zero stdio breakage** — opt-in transport

### Negative

- **Auth surface** — public-facing endpoint means real auth (bearer / mTLS / OIDC) needs implementation + careful review. Currently no public-facing surface; this is new attack surface.
- **Session-state management** — stdio is stateful by virtue of being a single long-lived process; HTTP is stateless per request. Bridge needs per-session state machine (rate-limit counters, OTel trace context, in-flight async work). Bounded, but new code.
- **Workers Durable Objects** — to hold session state in a Worker, Durable Objects are required. Adds complexity for Worker users; documented in the Workers-deployment guide.
- **Two transport code paths to maintain** — though most of the code (handler logic) is shared; only the I/O layer differs.
- **Cartridge incompatibility surfaces** — operators will discover at runtime that `browser-mcp` doesn't work on a Worker; `boj_capabilities` is the mitigation but it's a new contract clients have to learn.

## Non-goals

- **Not deprecating stdio** — stdio is the default and stays so. Most MCP clients use stdio; that's correct.
- **Not implementing custom transports** (WebSocket, gRPC) — Streamable HTTP+SSE is the spec; we follow it. If the spec evolves to add others, revisit.
- **Not building a hosted SaaS BoJ** — this RFC provides the transport; it doesn't run a public BoJ-as-a-service. That's a deployment choice.
- **Not changing tool/resource/prompt surfaces** — same MCP capabilities; just a new transport.
- **Not enabling cross-cartridge isolation** that doesn't exist on stdio. Cartridges that work locally work over HTTP; cartridges that need local resources don't suddenly become Worker-compatible.

## Open questions

1. **Session storage** — for a stdio process, session state is in-memory and disappears on process exit. For HTTP, do we persist session state across restarts? Recommend: ephemeral in-memory by default; opt-in to durable session storage (Redis / file) via `BOJ_HTTP_SESSION_STORE` env. Workers users use Durable Objects.

2. **Cold-start cost on Workers** — first request to a Worker initialises everything. Cartridge manifest loading + Nickel validator could be slow. Recommend: bundle the offline-menu + tool list into a static asset at build time so cold-start hits no I/O.

3. **SSE stream lifetime** — Workers have execution limits (~30s standard; longer with Durable Objects). What happens when the client expects a long-lived SSE stream and the Worker terminates? Recommend: documented as a Workers limitation; clients should reconnect on stream end.

4. **Backpressure under HTTP** — multiple clients to one BoJ instance can outpace cartridge dispatch capacity. Recommend: per-session rate limiting via ADR-0007 policy + global queue with bounded depth + 503 on overflow.

5. **TLS termination** — does the bridge speak TLS directly, or is it always behind a reverse proxy (nginx, Cloudflare, Caddy)? Recommend: behind a proxy by default; the bridge listens HTTP on localhost. TLS-direct mode opt-in via `BOJ_HTTP_TLS_*` env vars for operators who want a one-binary deployment.

6. **Compatibility with the existing `boj-rest` Cowboy listener** (port 7700) — the unreleased CHANGELOG mentions "boj-rest SSE surface: POST /cartridge/:name/sse on the same single Cowboy listener". Should the MCP HTTP transport mount on that same port (Cowboy already runs there), or a separate port? Recommend: same port; path-routed (`/mcp` vs `/cartridge/:name/*` vs `/webhooks/*`). Single listener honours ADR-0004.

## Implementation sketch

When this RFC is accepted (~1-2 weeks, two PRs):

**PR 1 — bridge HTTP transport** (~1 week)
1. New `mcp-bridge/lib/http-transport.js` — Cowboy / Hono / native http (TBD per runtime). Listen on `BOJ_HTTP_PORT`, dispatch JSON-RPC.
2. Session manager — issue UUIDs on initialize, maintain per-session state map, expire on timeout.
3. Auth middleware — bearer / mTLS / OIDC backends.
4. SSE handler — server-initiated notifications (per ADR-0011) fan out over the session's open SSE stream.
5. `mcp-bridge/main.js` reads `BOJ_TRANSPORT` and starts stdio, http, or both.
6. New env vars in `glama.json`: `BOJ_TRANSPORT`, `BOJ_HTTP_PORT`, `BOJ_HTTP_AUTH`, `BOJ_HTTP_AUTH_TOKENS`, `BOJ_HTTP_MTLS_CA`, `BOJ_HTTP_SESSION_STORE`.
7. `boj_capabilities` resource (per-deployment cartridge availability).
8. Tests: HTTP transport mirroring the stdio dispatch tests; auth-rejection tests; session-expiry tests.

**PR 2 — Workers deployment guide + Durable Objects shim** (~1 week)
1. New `docs/deployment/CLOUDFLARE-WORKERS.md` with wrangler config example.
2. Durable Object wrapper around the session manager.
3. Static bundling of the cartridge manifest so cold-start is cheap.
4. Example `wrangler.toml` showing minimum config.

Subsequent: native browser-client SDK (item 14 follow-up).

## Linked

- ADR-0002 (BoJ-only MCP) — HTTP transport is *within* BoJ, not a separate MCP server.
- ADR-0004 (unified gateway) — same Cowboy listener mounts `/mcp` alongside existing paths.
- ADR-0007 (policy DSL) — auth layer fronts the existing PEP; no policy changes.
- ADR-0009 (sandbox cartridge) — local sandbox backend incompatible with Workers; SaaS sandbox backends compatible.
- ADR-0010 (federation) — federation transport reuses this RFC's HTTP layer.
- ADR-0011 (webhooks/notifications) — `notifications/event` fan-out over the SSE stream defined here.
- Epic #87 item 14 (this).
