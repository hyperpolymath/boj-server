# BoJ-Server Handover Prompts

This directory mirrors the coord-MCP continuation prompts that live on
the author's Desktop so that a fresh clone has the full handover context
tracked in version control.

| File | Scope |
|------|-------|
| **`COORD-MCP-TODO.md`**              | **Tight actionable backlog, P0→P4, with agreed decisions D1–D4.** Start here. |
| **`COORD-MCP-STATE.md`**             | **Where we are now vs the forward vision — per-layer status + 38 decision summary.** |
| `COORD-MCP-DESIGN-LOG.md`            | Full design log — rationale + DD-1..DD-38 + appendices A–M. Reference for the two summaries above. |
| `COORD-MCP-HANDOFF-PROMPTS.md`       | Ready-to-paste prompts to re-seat a new Claude session |
| `COORD-MCP-PROMPT3-HANDOVER-2026-04-20.md` | Prompt 3 (coord finishers) handover — 11 tasks shipped |
| `COORD-DESIGN-ORIGIN-CONVERSATION.txt` | Raw conversation that seeded the design (BFT safety, affinity routing, adaptive horizon, chief-of-staff model). Historical. |

## Source of truth

The Desktop copies at `~/Desktop/COORD-MCP-*.md` remain the working
drafts the author edits in-session. These in-repo copies are the
canonical versions for anyone without Desktop access.

When a session updates a handover prompt, update **both** the Desktop
copy and the in-repo copy in the same commit. If they drift, the
in-repo copy wins.

## Current status (as of 2026-04-20 session close, commit `473733b` on main)

### Complete (sixteen tasks)

- **#1, #3–#8, #13–#17, #32, #35, #36, #37** — all shipped.
- 27 Zig tests + 41 Deno E2E assertions green. Panic-attack clean.
- Role terminology is now **master / journeyman / apprentice**;
  old names accepted at the boundary for one release.
- Track-record + affinity routing, dispatch preference, reassignment
  engine (server-origin quarantine), Nickel envelope validator,
  `coord_transfer_master`, `difficulty_hint` envelope + Nickel contract,
  `proof:<prover>` tag convention.
- 007-mcp family **#9–#12** marked complete in a separate repo
  (`The-Metadatastician/007` commits `62bdac0`, `018a1fd`, `6bbb4f8`,
  `e753d10`).

### Immediate next pick-up (Appendix L)

- **Task #33** — `client_kind` + `variant` extension (Peer struct
  changes, adapter JSON shape, log events 15 + 16).
- **Task #34** — capability advertisement.
- Estimate: ~1.5 days / ~5 commits. Concrete scope in
  `COORD-MCP-DESIGN-LOG.md` Appendix L.

### Also pending

- **Task #2** (low priority).
- **Proof Track P-04…P-07** Idris2 proofs in `Durability.idr`,
  ~6 days. **Keystone: P-06 replay-equivalence**.

## Warning for parallel sessions (shared-state files)

Do **not** run parallel sessions that both touch the `Peer` struct or
the `ClientKind` enum in the same wall-clock window:

- `cartridges/local-coord-mcp/ffi/local_coord_ffi.zig`
- `cartridges/local-coord-mcp/adapter/local_coord_adapter.zig`

Everything else can parallelise safely.

## Untracked from other tracks (intentionally not committed)

- `.machine_readable/contractiles/bust/` — belongs to a different lane.
