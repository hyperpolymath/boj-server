<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Prompt 3 handover — coord finishers are done (2026-04-20 afternoon)

**Read first, then carry on.** This note is for the other Claude session
that's still in the Prompt 2 lane (007-mcp cartridge family, tasks
#9–12). It tells you exactly what landed from the coord-finishers side
so you don't duplicate or contradict it.

---

## What shipped

Eleven tasks, all pushed to `hyperpolymath/boj-server` `main`:

| # | Title | Commits |
|---|-------|---------|
| 13 | Track-record table + `effective_affinity` + `coord_get_affinities` | `f8cafbf`, `3bd4710` |
| 15 | Dispatch preference + task_difficulty + sender_confidence + reject cooldown | `6065878` |
| 14 | Reassignment engine (server-origin quarantine entries for master review) | `9e40a86` |
| 17 | Deno/Node Nickel shim — runtime envelope validation in mcp-bridge | `ed85ca2` |
| 32 | Role rename supervisor/executor/supervised → master/journeyman/apprentice | `634c163` (merged with #35) |
| 35 | `coord_transfer_master` — live master handoff | `634c163` |
| 36 | `difficulty_hint` envelope field + `DifficultyHintValid` Nickel contract | `7f2f4a9`, `aeae440` |
| 37 | Prover-tag convention doc (`proof:lean4`/`agda`/`idris2`/`rocq`/`tla`) + example | `eba7cfe` |

Design log updated in-tree: `Desktop/COORD-MCP-DESIGN-LOG.md` Part 2
ledger has the full task table and new commit refs.

## APIs you can use from 007-mcp

If you're building on top of the coord layer from 007-mcp, these new
tools + FFI entrypoints are now live:

- **MCP tools** (all routed through mcp-bridge at loopback:7745):
  - `coord_report_outcome(token, tag, outcome, risk_tier, duration_ms?, confidence?)`
  - `coord_get_affinities(token)` — per (client_kind, tag) aggregates
  - `coord_set_declared_affinities(token, tags[])`
  - `coord_scan_suggestions(token)` — enqueues candidate fyi/clarify
    envelopes into the quarantine for master review
  - `coord_transfer_master(token, new_peer_id, secret)`
  - `coord_register` accepts optional `declared_affinities: string[]`
  - `coord_claim_task` accepts optional `confidence`,
    `dispatch_preference`, `task_difficulty`

- **Envelope fields** (validated by Nickel contracts in mcp-bridge
  before they hit the Zig adapter):
  - `sender_confidence: number in [0, 1]`
  - `dispatch_preference: "deliberate" | "broadcast" | "auto"`
  - `task_difficulty: "trivial" | "routine" | "challenging" | "novel"`
  - `difficulty_hint: "low" | "medium" | "high"` — orthogonal to `risk_tier`

- **Prover-tag convention** (zero code): task tags prefixed
  `proof:<prover>` route to peers whose `declared_affinities` cover that
  prover. Worked example in
  `cartridges/local-coord-mcp/schemas/examples/prover-tag-claim.ncl`.

## Terminology — DD-32 role rename

If 007-mcp has any supervisor/executor/supervised strings, they need to
move to master/journeyman/apprentice. The old names are accepted as
aliases for one release at the registration boundary but should not
appear in new code. Integer ordinals are preserved (0/1/2) so durable
logs still replay.

Env var: `BOJ_MASTER_TOKEN` (canonical). `BOJ_SUPERVISOR_TOKEN` read as
fallback for one release.

## Things that DID NOT land (deferred, in Appendix M)

- **Task #33** — `client_kind` extension with `openai`, `mistral` +
  `variant` free-form string. No code yet.
- **Task #34** — capability advertisement on register (class ∈
  {reasoner, coder, mathematician, scribe, proofsmith, reader, jester};
  tier ∈ {A, B, C}; `prover_strengths` map). No code yet.

If you need the `class` or `variant` fields from 007-mcp, they don't
exist yet — either stub around them or pick up Task #33/#34 first.

## Things to watch for

- **Quarantine queue still has `MAX_QUARANTINE=32`.** The reassignment
  engine enqueues server-origin entries alongside real peer entries, so
  the queue can fill faster now. If you see `coord_send_gated` return
  -4 (queue full) from 007-mcp, consider raising the constant or
  triggering `coord_scan_suggestions` less frequently.

- **Rejection cooldown is per-client_kind, not per-peer.** 5 rejections
  in 10 min across any `kind=claude` peer triggers a 30s cooldown on
  all `kind=claude` claim attempts. If you spin up many Claude sessions
  against one coord server, be aware.

- **Parallel changes in coord-messages.ncl.** The envelope shape schema
  gained `dispatch_preference`, `task_difficulty`, `difficulty_hint`
  during this lane. `additionalProperties=false` means these are
  accepted; anything else still gets rejected.

## Uncommitted work NOT from this lane

At time of writing the working tree has four modified files that look
like part of the parallel session's ongoing work (rename pass sweeping
through the rest of the cartridge, plus your E2E test extensions):

- `cartridges/local-coord-mcp/abi/LocalCoord/PROOF-SCHEDULE.adoc`
- `cartridges/local-coord-mcp/cartridge.ncl`
- `cartridges/local-coord-mcp/schemas/test-contracts.sh`
- `cartridges/local-coord-mcp/tests/e2e_coord.ts`

…and an untracked `.machine_readable/contractiles/bust/` directory
(`Bustfile.a2ml` + `bust.ncl`). These are left alone; commit or stash
as appropriate in your lane.

## Re-orientation quick path

If you're coming in cold: read `Desktop/COORD-MCP-DESIGN-LOG.md` Part 2
ledger + Appendix M + Appendix L. Every decision is indexed in Part 3
(DD-1 through DD-37). Every commit lands in Part 2's table.

— Opus (1M context), 2026-04-20 afternoon
