# boj-server

[![OpenSSF Best Practices](https://img.shields.io/badge/OpenSSF-Best_Practices-green?logo=opensourcesecurity)](https://www.bestpractices.dev/en/projects/new?repo_url=https://github.com/hyperpolymath/boj-server)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/hyperpolymath/boj-server/badge)](https://scorecard.dev/viewer/?uri=github.com/hyperpolymath/boj-server)
[![Glama MCP Server](https://glama.ai/mcp/servers/hyperpolymath/boj-server/badge)](https://glama.ai/mcp/servers/hyperpolymath/boj-server)
[![Green Hosting](https://api.thegreenwebfoundation.org/greencheckimage/boj-server.net)](https://www.thegreenwebfoundation.org/green-web-check/?url=boj-server.net)
[![Software Heritage](https://archive.softwareheritage.org/badge/origin/https://github.com/hyperpolymath/boj-server/)](https://archive.softwareheritage.org/browse/origin/?origin_url=https://github.com/hyperpolymath/boj-server)

BoJ (Bundle of Joy) is a unified MCP server that consolidates all hyperpolymath tooling into a single endpoint — GitHub, GitLab, Cloudflare, Vercel, Verpex, Gmail, Calendar, browser automation, research, ML, and 115 open-source cartridges.

## Install

Add to Claude Code:

```bash
claude mcp add boj-server -- npx -y @hyperpolymath/boj-server@latest
```

Or clone and configure:

```bash
git clone https://github.com/hyperpolymath/boj-server
cd boj-server/mcp-bridge && npm install
# Start the BoJ REST API first (port 7700), then:
claude mcp add boj-server -- deno run -A mcp-bridge/main.js
```

Glama listing: <https://glama.ai/mcp/servers/hyperpolymath/boj-server>

## Features

- **GitHub/GitLab** — repos, issues, PRs, code search, mirroring (22 tools)
- **Cloud** — Cloudflare (DNS, Workers, KV, R2, D1), Vercel (deployments, projects), Verpex (cPanel)
- **Communication** — Gmail, Google Calendar
- **Browser** — Firefox automation: navigate, click, type, screenshot, arbitrary JS (7 tools)
- **Code Intelligence** — CodeSeeker hybrid search + graph RAG
- **Research** — Semantic Scholar papers, citations, authors
- **ML** — Hugging Face model / dataset / inference
- **Local coordination** — `local-coord-mcp` (24 tools): multi-instance AI peer discovery, typed envelopes, claim/heartbeat/watchdog, quarantine + master/journeyman/apprentice supervision, track-record affinity, capability advertisement
- **Cartridges** — 115 pluggable cartridges across Teranga / Shield / Ayo trust tiers

## Local-coord-mcp at a glance

Localhost multi-agent bus on `127.0.0.1:7745`. Lets multiple Claude / Gemini / Codex / Vibe sessions on the same machine discover each other, claim tasks without collision, and operate under a supervision model (master approves; journeyman executes; apprentice stays gated).

Highlights:

- **Peer registration** with `client_kind`, `variant` (model id — `opus-4.7`, `flash-2.5`, `leanstral`), capability class/tier/prover-strengths — `coord_register`, `coord_set_variant`, `coord_set_capabilities`, `coord_get_peer_capabilities`.
- **Typed envelopes** validated at the bridge via Nickel contracts (`coord-messages.ncl`) — `coord_send`, `coord_send_gated`.
- **Task claims** with role-based watchdog TTL (apprentice 30s / journeyman 5m / master none), heartbeats via `coord_progress`, auto-release + explicit `coord_sweep_watchdog`.
- **Track-record + reassignment** — `coord_report_outcome`, `coord_get_affinities`, `coord_scan_suggestions` (emits `overclaim` fyi + `drift` warn envelopes on confidence/affinity divergence).
- **Supervision** — `coord_review`, `coord_approve`, `coord_reject`, `coord_promote_to_master`, `coord_transfer_master`.
- **Observability** — `coord_health` snapshot of peer/quarantine/claim/reject state.

Formally verified core in Idris2 (`cartridges/local-coord-mcp/abi/LocalCoord/`); Zig FFI; Deno/Node MCP bridge with input hardening (rate limiting, prompt-injection detection with unicode-normalisation, error sanitisation).

## Glama AAA posture

This server targets Glama's AAA tier. Posture:

- **Inspectable** — `.mcp.json` + root `package.json` `bin` entry + shebang; offline manifest fallback so cloud inspection works without the REST backend (see `mcp-bridge/lib/offline-menu.js`).
- **Tool Definition Quality** — every tool carries purpose, usage guidance, behavioural transparency (side effects, returns, errors), and parameter semantics with enums, ranges, and patterns. A coherence test enforces a minimum description floor so the server-level score (60% mean + 40% *min*) cannot regress — see `mcp-bridge/tests/dispatch_test.js`.
- **Server Coherence** — one tool ↔ one verb; consistent `boj_<domain>_<action>` and `coord_<action>` naming; the same test asserts the bridge tool list matches the cartridge manifest so nothing advertised is un-dispatched (or vice versa).
- **Security** — PR #27 hardening: rate limiting, size caps, prompt-injection detection with unicode-confusable normalisation, error sanitisation (strips paths, stack traces, env vars). SHA-pinned workflow actions.
- **Formal** — `cartridges/local-coord-mcp/abi/LocalCoord/*.idr` Idris2 ABI + proof obligations (P-01..P-07).

Run the coherence tests:

```bash
npm test
```

## Citing

If you use BoJ Server in academic work, citation metadata is in [`CITATION.cff`](./CITATION.cff). GitHub renders a "Cite this repository" button in the sidebar from this file.

Per-release DOIs are available via Zenodo. To enable them:

1. Log in to [zenodo.org](https://zenodo.org/) with your GitHub account.
2. Account → GitHub → flip the **boj-server** repository toggle to on.
3. Cut a new GitHub release; Zenodo auto-archives it and mints a DOI.
4. Add the DOI badge to this README:
   ```markdown
   [![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.XXXXXXX.svg)](https://doi.org/10.5281/zenodo.XXXXXXX)
   ```
5. Update the `doi:` field in `CITATION.cff` to match.

## License

MPL-2.0 — see [LICENSE](./LICENSE).
