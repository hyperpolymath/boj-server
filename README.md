<!--
SPDX-License-Identifier: MPL-2.0
SPDX-FileCopyrightText: 2025-2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# BoJ Server (Bundle of Joy)

**One MCP endpoint for the whole hyperpolymath toolchain** — GitHub, GitLab, Cloudflare, Vercel, Verpex, Gmail, Calendar, browser automation, research, ML, multi-agent coordination, and a large catalogue of pluggable domain cartridges, all reachable through a single zero-dependency stdio bridge.

[![License: MPL-2.0](https://img.shields.io/badge/License-MPL_2.0-blue.svg)](LICENSE)
[![npm](https://img.shields.io/npm/v/@hyperpolymath/boj-server?logo=npm)](https://www.npmjs.com/package/@hyperpolymath/boj-server)
[![Glama MCP Server](https://glama.ai/mcp/servers/hyperpolymath/boj-server/badge)](https://glama.ai/mcp/servers/hyperpolymath/boj-server)
[![OpenSSF Best Practices](https://img.shields.io/badge/OpenSSF-Best_Practices-green?logo=opensourcesecurity)](https://www.bestpractices.dev/en/projects/new?repo_url=https://github.com/hyperpolymath/boj-server)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/hyperpolymath/boj-server/badge)](https://scorecard.dev/viewer/?uri=github.com/hyperpolymath/boj-server)
[![Software Heritage](https://archive.softwareheritage.org/badge/origin/https://github.com/hyperpolymath/boj-server/)](https://archive.softwareheritage.org/browse/origin/?origin_url=https://github.com/hyperpolymath/boj-server)
[![Quality gate](https://sonarcloud.io/api/project_badges/quality_gate?project=hyperpolymath_boj-server)](https://sonarcloud.io/summary/new_code?id=hyperpolymath_boj-server)

> **What it is, honestly:** BoJ exposes **68 MCP tools** today (45 `boj_*` + 23 `coord_*`) over stdio with **zero runtime dependencies**. It *catalogues* 125 domain cartridges, but most of those are an inspectable catalogue, not live services — a cartridge only performs real actions when its backend process is running and you supply the right credentials. The bridge is fully inspectable offline; side-effectful tools return a structured `{error, hint}` until their backend is up. See [Cartridges](#cartridges) for the full story.

---

## Contents

- [Features](#features)
- [Install](#install)
- [Quickstart](#quickstart)
- [Capabilities overview](#capabilities-overview)
- [Cartridges](#cartridges)
- [Backend](#backend)
- [Transports](#transports)
- [Configuration](#configuration)
- [Security](#security)
- [License](#license)
- [Contributing & links](#contributing--links)

---

## Features

- **Unified endpoint** — GitHub/GitLab, Cloudflare/Vercel/Verpex, Gmail/Calendar, Firefox browser automation, CodeSeeker code intelligence, Semantic Scholar research, and Hugging Face ML, all behind one MCP server.
- **68 MCP tools** — 45 `boj_*` (5 core discovery/dispatch + explicit high-frequency tools) and 23 `coord_*` multi-agent coordination tools.
- **125-cartridge catalogue** — a single `boj_cartridge_invoke` reaches any catalogued cartridge; explicit `boj_<domain>_<verb>` tools exist for the highest-frequency operations.
- **Multi-instance AI coordination** — `local-coord-mcp` lets several Claude / Gemini / Codex sessions on one machine discover each other, claim tasks without collision, and run under a master/journeyman/apprentice supervision model.
- **Zero runtime dependencies** — the bridge runs on Node, Deno, or Bun with no install step.
- **Inspectable offline** — `boj_health`, `boj_menu`, `boj_cartridges`, and `boj_cartridge_info` answer from an offline manifest so clients can introspect the server without any backend running.
- **MCP resources & prompts** — 7 `boj://` resources and reusable prompts (`audit-repo`, `convene-cluster`, `deploy-with-dns-ssl`, `summarize-channel`, `triage-issues`, `proof-status`).
- **Hardened** — per-call rate limiting, size caps, prompt-injection detection with Unicode-confusable normalisation, and error sanitisation (paths, stack traces, and env vars stripped from responses).
- **Formally verified core** — the coordination ABI is written in Idris2 with discharged proof obligations; remaining axioms are documented, not hidden.

---

## Install

BoJ ships as an MCP server over **stdio**. The published npm package (`@hyperpolymath/boj-server`) has **zero runtime dependencies**, so no install step is ever required regardless of runtime.

> Most cartridges call the BoJ REST backend on `http://localhost:7700`. Without it, the server is still fully inspectable; side-effectful tools return `{error, hint}`. See [Backend](#backend).

### Claude Code (CLI)

```bash
claude mcp add boj-server -- npx -y @hyperpolymath/boj-server@latest
```

### Claude Desktop

Edit `claude_desktop_config.json`:

- **macOS** — `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows** — `%APPDATA%\Claude\claude_desktop_config.json`
- **Linux** — `~/.config/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "boj-server": {
      "command": "npx",
      "args": ["-y", "@hyperpolymath/boj-server@latest"],
      "env": { "BOJ_URL": "http://localhost:7700" }
    }
  }
}
```

Restart Claude Desktop after saving.

### npx (any MCP client)

The minimum stdio spec is `command: npx`, `args: ["-y", "@hyperpolymath/boj-server@latest"]`. Optional env: `BOJ_URL` (default `http://localhost:7700`). This works with VS Code / Copilot, Cursor, Cline, Windsurf, Continue.dev, Zed, and the Gemini CLI — point each client's MCP config at that command. This repo's `.mcp.json` is a working reference config.

### Deno / Bun / Node (from a clone)

The bridge entrypoint is `mcp-bridge/main.js` and runs on any of the three runtimes with no install:

```bash
# Deno (no install step; the project's documented runtime)
deno run -A /path/to/boj-server/mcp-bridge/main.js

# Bun (zero-install)
bun /path/to/boj-server/mcp-bridge/main.js

# Node (>= 18)
node /path/to/boj-server/mcp-bridge/main.js
```

---

## Quickstart

After install, ask your LLM: *"Use the `boj_health` tool."* You get `{status:"ok", uptime_s, version}` when the backend is up, or a structured hint when it is offline.

To talk to the bridge directly over stdio, send newline-delimited JSON-RPC. Initialize, then list tools:

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | node mcp-bridge/main.js
```

The `initialize` response reports protocol `2024-11-05` and server `boj-server`; `tools/list` returns **68** tool definitions (45 `boj_*`, 23 `coord_*`), each carrying a full description, JSON-Schema `inputSchema`/`outputSchema`, and MCP behaviour annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`).

Call a tool:

```jsonc
{ "jsonrpc": "2.0", "id": 3, "method": "tools/call",
  "params": { "name": "boj_health", "arguments": {} } }
```

The server also implements `resources/list` (7 `boj://` resources) and `prompts/list`.

---

## Capabilities overview

The bridge exposes **45 `boj_*` tools** and **23 `coord_*` tools**. A subset of cartridges have explicit `boj_<domain>_<verb>` tools for high-frequency operations; everything catalogued is reachable through `boj_cartridge_invoke`.

| Group | Tools | Examples |
|---|---|---|
| **Core discovery / dispatch** | 5 | `boj_health`, `boj_menu`, `boj_cartridges`, `boj_cartridge_info`, `boj_cartridge_invoke` |
| **GitHub** | 14 | `boj_github_list_repos`, `boj_github_create_issue`, `boj_github_create_pr`, `boj_github_merge_pr`, `boj_github_search_code`, `boj_github_graphql` |
| **GitLab** | 8 | `boj_gitlab_list_projects`, `boj_gitlab_create_mr`, `boj_gitlab_list_pipelines`, `boj_gitlab_setup_mirror` |
| **Browser (Firefox)** | 7 | `boj_browser_navigate`, `boj_browser_click`, `boj_browser_type`, `boj_browser_read_page`, `boj_browser_screenshot`, `boj_browser_tabs`, `boj_browser_execute_js` |
| **Cloud** | 3 | `boj_cloud_cloudflare`, `boj_cloud_vercel`, `boj_cloud_verpex` |
| **Communications** | 2 | `boj_comms_gmail`, `boj_comms_calendar` |
| **Research / code intel / ML / search** | 4 | `boj_research`, `boj_codeseeker`, `boj_ml_huggingface`, `boj_search` |
| **Coordination (`local-coord-mcp`)** | 23 | `coord_register`, `coord_claim_task`, `coord_send`, `coord_review`, `coord_approve`, `coord_health` |

> Set `BOJ_TOOL_SCOPE=core` to advertise only the discovery surface; explicit `boj_<domain>_*` tools remain reachable via `boj_cartridge_invoke` regardless. A CSV of prefixes (e.g. `core,github,browser`) advertises core plus named groups.

### Multi-agent coordination (`coord_*`)

A localhost multi-agent bus (default `127.0.0.1:7745`) lets multiple AI sessions on one machine discover each other, claim tasks without collision, and operate under supervision (master approves; journeyman executes; apprentice stays gated):

- **Peers** — `coord_register`, `coord_list_peers`, `coord_set_variant`, `coord_set_capabilities`, `coord_get_peer_capabilities`.
- **Typed envelopes** — `coord_send`, `coord_send_gated`, `coord_receive` (Nickel-contract validation, opt-in strict mode).
- **Task claims** — `coord_claim_task` with role-based watchdog TTL, `coord_progress` heartbeats, `coord_sweep_watchdog`, optional advisory `paths` for `path_overlap` warnings.
- **Track record** — `coord_report_outcome`, `coord_get_affinities`, `coord_set_declared_affinities`, `coord_scan_suggestions` (emits `overclaim`/`drift` advisory envelopes).
- **Supervision** — `coord_review`, `coord_review_entry`, `coord_approve`, `coord_reject`, `coord_promote_to_master`, `coord_transfer_master`, plus `coord_status` / `coord_health`.

Task-claim collision-freedom is a **task-level** guarantee, not a git-level lock: two journeymen claiming *different* tasks that touch the same file can still hit a vanilla merge conflict. The supported pattern is branch-per-claim + per-peer worktree, advisory path-claims, and master-gated integration. The companion terminal UI lives in [`coord-tui/`](coord-tui/) and at [hyperpolymath/coord-tui](https://github.com/hyperpolymath/coord-tui).

---

## Cartridges

BoJ catalogues **125 cartridges** across trust tiers (Teranga / Shield / Ayo). Be clear about what that means:

- **Catalogued ≠ live.** `boj_menu` lists the full catalogue, but most cartridges report `available: false`. They are entries describing a capability — its API base URL, auth model (often brokered through `vault-mcp`), and any native FFI path — not a running service.
- **A cartridge becomes available when** (1) its backend process is running and reachable via the BoJ REST API, and (2) you have supplied the credentials it needs.
- **Credentials** are typically environment variables (`GITHUB_TOKEN`, `GITLAB_TOKEN`, `CF_API_TOKEN`, OAuth tokens, …) or are brokered by the `vault-mcp` credential cartridge. `boj_cartridge_info <name>` returns the cartridge's manifest, including the exact auth requirement.
- **Without backend or credentials**, side-effectful tools return a structured `{error, hint}` telling you what's missing — they never silently fail.

> **Number transparency:** **125** is the single source of truth — it is the number of `cartridge.json` manifests under `cartridges/` and what the live `boj_menu` reports. Every packaging file (`package.json`, `jsr.json`, `smithery.yaml`, `ai-plugin.json`, `openapi.yaml`, `CITATION.cff`) is reconciled to it. Of those 125, most are a catalogue entry rather than a live service — see the bullets above.

Catalogued domains include: git forges & code hosting, cloud platforms (Cloudflare, Vercel, AWS, GCP, DigitalOcean, Hetzner, Fly, Linode, Railway, Render), databases (PostgreSQL, MongoDB, Redis, Neo4j, ClickHouse, DuckDB, Turso, Supabase, Neon, …), containers & Kubernetes, CI/CD & observability (Buildkite, CircleCI, Hypatia, Grafana, Prometheus, Sentry), messaging (Slack, Discord, Telegram, Matrix), productivity (Notion, Linear, Jira, Obsidian, Zotero), ML/AI & coordination, browser & web automation, code intelligence & research, developer tooling (LSP/DAP/BSP, language & package registries), security & secrets, IaC & proof systems, and hyperpolymath-native admin cartridges.

---

## Backend

Most cartridges (GitHub/GitLab, cloud, ML, browser, CodeSeeker, etc.) call the BoJ REST API — an **Elixir** service on **`http://localhost:7700`**. Two modes:

1. **Run BoJ locally** — clone this repo and `just run` (see [`docs/quickstarts/USER.adoc`](docs/quickstarts/USER.adoc)). The REST API serves on port `7700`.
2. **Inspectable mode only** — without the backend, `boj_health`, `boj_menu`, `boj_cartridges`, and `boj_cartridge_info` still respond from the offline manifest, so any MCP client can introspect the server. Side-effectful tools return `{error, hint}` until the backend is up.

> **Note on versions:** when the backend is offline, `boj_health` may report a placeholder backend version (`0.1.0`) from the bundled offline manifest — this is the manifest's hardcoded value, not the npm package version (`0.4.7`). The MCP bridge itself reports `0.4.7` at `initialize`.

The coordination bus (`local-coord-mcp`) is a separate localhost service, default `http://127.0.0.1:7745` (`COORD_BACKEND_URL`).

---

## Transports

Selected with `BOJ_TRANSPORT` (ADR-0013):

| Value | Behaviour |
|---|---|
| `stdio` *(default)* | Reads JSON-RPC from stdin, writes to stdout — how Claude Code / Desktop launch the bridge as a subprocess. |
| `http` | Starts an HTTP+SSE listener on `BOJ_HTTP_PORT` (default `7780`) for remote / Workers / browser deployments. Binds `127.0.0.1` by default; `BOJ_HTTP_AUTH=none` is **refused** on a non-loopback bind. |
| `both` | Runs stdio and HTTP simultaneously. |

HTTP auth: `none` (loopback only), or `bearer` against `BOJ_HTTP_AUTH_TOKENS`. `mtls`/`oidc` are planned, not yet implemented.

---

## Configuration

Key environment variables (full schema in [`glama.json`](glama.json)):

| Variable | Default | Purpose |
|---|---|---|
| `BOJ_URL` | `http://localhost:7700` | Base URL for the BoJ REST backend. |
| `GITHUB_TOKEN` | — | PAT for `boj_github_*` tools. |
| `GITLAB_TOKEN` / `GITLAB_URL` | — / `https://gitlab.com` | Token + base URL for `boj_gitlab_*` tools. |
| `BOJ_TOOL_SCOPE` | `full` | `full`, `core`, or a CSV of domain prefixes (e.g. `core,github,browser`). |
| `BOJ_RATE_LIMIT` | `60` | Max tool calls per minute. |
| `BOJ_LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` / `silent`. |
| `BOJ_TRANSPORT` | `stdio` | `stdio` / `http` / `both`. |
| `BOJ_HTTP_PORT` / `BOJ_HTTP_BIND` | `7780` / `127.0.0.1` | HTTP transport port and bind address. |
| `BOJ_HTTP_AUTH` / `BOJ_HTTP_AUTH_TOKENS` | `none` / — | HTTP auth mode and accepted bearer tokens. |
| `COORD_BACKEND_URL` | `http://127.0.0.1:7745` | Coordination bus backend. |
| `COORD_REQUIRE_NICKEL` | `0` | `1` enables strict Nickel-contract validation on gated envelopes. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | — | When set, every `tools/call` emits an OTLP/JSON span to `<endpoint>/v1/traces`. |

---

## Security

- **Input hardening** — per-call rate limiting (`BOJ_RATE_LIMIT`), request size caps, and prompt-injection detection with Unicode-confusable normalisation.
- **Error sanitisation** — responses strip filesystem paths, stack traces, and environment variables before they reach the client.
- **HTTP safety** — `BOJ_HTTP_AUTH=none` is refused on any non-loopback bind; bearer auth is required for remote exposure.
- **Credential isolation** — cartridge credentials are supplied per-cartridge (env vars or the `vault-mcp` broker), never embedded in tool definitions.
- **Formal verification** — the coordination ABI safety layer is written in Idris2 with discharged proof obligations; remaining `believe_me` sites are isolated, documented axioms over the compiler's opaque `Char`/`String` primitives, tracked in [`PROOF-NEEDS.md`](PROOF-NEEDS.md).
- **Supply chain** — SHA-pinned GitHub Actions; coherence tests assert the advertised tool list matches the cartridge manifest so nothing is advertised-but-undispatched.

Run the coherence tests:

```bash
node --test mcp-bridge/tests/
```

Report vulnerabilities per [`SECURITY.md`](SECURITY.md).

---

## License

- **Code** — [MPL-2.0](LICENSE) (Mozilla Public License 2.0) — the license published to npm and detected by GitHub.
- **Documentation** — MPL-2.0 today (the repository's REUSE config tags every file MPL-2.0); a **CC-BY-SA-4.0** split for prose is the intended model, with the docs-licence rollout tracked as a follow-up.

This project **does not** use AGPL; any AGPL string remaining in a build manifest is a packaging regression, not the project's license.

---

## Contributing & links

- **Repository** — [github.com/hyperpolymath/boj-server](https://github.com/hyperpolymath/boj-server)
- **npm** — [`@hyperpolymath/boj-server`](https://www.npmjs.com/package/@hyperpolymath/boj-server)
- **Glama listing** — [glama.ai/mcp/servers/hyperpolymath/boj-server](https://glama.ai/mcp/servers/hyperpolymath/boj-server)
- **Coordination TUI** — [hyperpolymath/coord-tui](https://github.com/hyperpolymath/coord-tui)
- **Contributing** — see [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
- **Citing** — citation metadata is in [`CITATION.cff`](CITATION.cff); GitHub renders a "Cite this repository" button from it.

Maintained by Jonathan D.A. Jewell.
