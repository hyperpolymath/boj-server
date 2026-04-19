# BoJ-Server Handover Prompts

This directory mirrors the coord-MCP continuation prompts that live on
the author's Desktop so that a fresh clone has the full handover context
tracked in version control.

| File | Scope |
|------|-------|
| `COORD-MCP-DESIGN-LOG.md`            | Master design log — rationale + Part 1/2 ledger of landed tasks |
| `COORD-MCP-HANDOFF-PROMPTS.md`       | Prompt matrix — which prompt to use when |
| `COORD-MCP-PROMPT3-HANDOVER-2026-04-20.md` | Prompt 3 (coord finishers) handover — 11 tasks, 10 commits, shipped |

## Source of truth

The Desktop copies at `~/Desktop/COORD-MCP-*.md` remain the working
drafts the author edits in-session. These in-repo copies are the
canonical versions for anyone without Desktop access.

When a session updates a handover prompt, update **both** the Desktop
copy and the in-repo copy in the same commit. If they drift, the
in-repo copy wins.

## Current status (as of 2026-04-20)

- **Prompt 3 (coord finishers)**: SHIPPED — 11 tasks, 10 commits, all
  pushed to `origin/main`. Track-record + affinity routing, dispatch
  preference, reassignment engine, Nickel envelope validator, role
  rename (master/journeyman/apprentice) + `coord_transfer_master`,
  `difficulty_hint` envelope + Nickel contract, `proof:<prover>` tag
  convention.
- **Prompt 2 (007-mcp family)**: IN PROGRESS in parallel lane. New
  tools + FFI entries ready for 007-mcp: `affinities`,
  `declared_affinities`, `scan_suggestions`, `transfer_master`.
  Role terminology is now master/journeyman/apprentice; old names
  accepted at boundary for one release.
- **Deferred** (Appendix M): Tasks #33 (client_kind+variant) and #34
  (capability advertisement).

## Parallel-session uncommitted work (do not touch)

These belong to the Prompt 2 / parallel-session lane as of 2026-04-20:

- `cartridge.ncl` (modified)
- `PROOF-SCHEDULE.adoc` (modified)
- `test-contracts.sh` (modified)
- `tests/e2e_coord.ts` (modified)
- `.machine_readable/contractiles/bust/` (untracked)
