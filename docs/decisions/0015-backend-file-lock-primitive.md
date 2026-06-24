<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# 15. Backend-enforced file-lock primitive — spike

Date: 2026-05-24

## Status

Deferred (2026-05-24) — ADR-0016 (cross-host federation stop-gap) was
chosen as the next build over this one because it closes a more
user-visible survey gap without altering the verified backend core.
The bridge-layer advisory path-claims shipped in PR #142/#143 remain
the current answer for in-flight conflict signalling.

This ADR stays on file as the design-of-record for a backend-enforced
lock primitive should "advisory warning is not enough" become a stated
requirement. Reopen by flipping to "Proposed" and scheduling alongside
the next P-0x proof-obligation cycle.

## Context

The multi-agent MCP survey identified that two comparator servers
(`rinadelph/Agent-MCP`, `AndrewDavidRivers/multi-agent-coordination-mcp`)
ship **hard file locks** at claim time, whereas `local-coord-mcp` has
only the bridge-layer **advisory** path-claims added in PR #142 / PR #143.
The survey marked file-level locks as a clear gap relative to those two.

This spike evaluates promoting path-claims from "bridge-only advisory
warning" to a **backend-enforced lock primitive** in the verified Idris2
ABI + Zig FFI.

## What the change does

1. Extend the `LocalCoord` Idris2 ABI with a new tool surface:
   `coord_lock_paths(token, task, paths[])` and
   `coord_unlock_paths(token, task)`. Paths are interned, normalised, and
   the backend maintains an authoritative `task → segment[][]` map
   alongside the existing claim map.
2. The lock check runs **inside** `coord_claim_task` when `paths` is
   present: if any declared path segment-overlaps an existing locked
   path held by another peer, the claim is **rejected** (not annotated).
   Today's bridge-layer overlap scan becomes a projection of the
   backend's authoritative state.
3. New proof obligation **P-08: LockSoundness** in
   `cartridges/local-coord-mcp/abi/LocalCoord/Locks.idr`, discharged by
   construction:
   - **Mutual exclusion** — no two distinct tasks simultaneously hold
     overlapping paths (segment-prefix-disjoint).
   - **Lock-claim composition** — a granted claim's path-locks survive
     until `coord_unlock_paths` or watchdog expiry; never silently
     released by a different peer.
   - **Watchdog interaction** — when the claim's role-based TTL fires
     (P-03 WatchdogTermination), the lock-set is released atomically
     with the claim.
4. Cartridge schema bump: `cartridge.json` adds the two new tools and
   widens `coord_claim_task` to declare `path_locked` as a rejection
   reason in its output schema. Coherence test (`dispatch_test.js`)
   already enforces bridge↔cartridge sync, so the bridge tool list and
   dispatcher must update in lockstep.

## Cost

| Surface | Work |
|---|---|
| Idris2 ABI | New `Locks.idr` module + P-08 discharge. Roughly 200-300 lines of Idris2; the segment-prefix proof reduces to list-prefix induction on `List String`, which is constructive (no new `believe_me`). |
| Zig FFI | `boj_coord_lock_paths` / `boj_coord_unlock_paths` exports + an internal `PathLockTable` (radix tree or sorted-array; flat array is fine at expected scale). ~150 LOC. |
| Bridge | Demote `path-claims.js` to a stateless projection — query the backend's lock table on demand rather than maintaining its own. Or delete it. |
| Cartridge schema | Two new tool entries; one output-shape widening on `coord_claim_task`. |
| Tests | New Idris2 totality proofs (P-08), Zig unit tests, bridge integration tests, bench update. |

Estimated: 2-4 working days end-to-end.

## Benefit

- Closes the survey gap **completely**: backend-enforced locks rather
  than an advisory layer. Strongest answer.
- Idris2 proof gives a guarantee neither Agent-MCP nor multi-agent-coord
  has — they ship runtime-checked locks, we'd ship a *proved-correct*
  lock primitive. Aligns with the AAA Formal posture (P-01..P-07).
- The bridge-layer code shrinks (path-claims.js largely becomes a
  pass-through projection), which is a healthy direction.

## Risks / open questions

- **Architectural regression risk.** Today's design is explicit: the
  verified backend stays minimal and the bridge layers advisory
  features. Adding state to the backend (path-locks) is the first time
  a non-task-id concept enters the proved core. P-08 must not weaken
  the existing proofs — needs careful composition argument.
- **Schema-evolution lock-in.** Once `coord_lock_paths` is in the
  cartridge manifest, removing it is a breaking change. Path-semantics
  (segment-prefix matching) gets baked into the wire contract.
- **Defines vs. enforces.** What does the backend do when a *non-path*
  claim conflicts with a locked path? The current advisory layer is
  silent in that case; an enforcer must take a position.
- **Failure modes change.** Today a clashing path is a *warning*; under
  this proposal it's a *claim rejection*. Existing rate-limit (5
  rejections / 10 min → 30s cooldown) applies; either way, agents need
  retry logic.

## Verdict

Strongest technical answer to the survey gap, but the largest
architectural commitment in this branch of work. The proof load
(P-08) is tractable — segment-prefix mutual exclusion is structurally
inductive — but the *design* commitment (locks as a first-class backend
concept) deserves the user's explicit sign-off, not an implementer's
judgement call.

**Recommendation:** Choose this only if "advisory warning is not
enough" is a stated requirement. Otherwise, prefer ADR-0016
(cross-host federation stop-gap), which closes a different and arguably
more user-visible survey gap (Ruflo being the only comparator with real
cross-host story) without altering the verified core.

## Out of scope

- File-range locks (byte ranges within a file). Not addressed — paths
  are still whole-file. The Perforce-style range lock would be a
  separate, larger ADR.
- Lock fairness / queueing on contention. This spike rejects on
  overlap; a queue would be a P-09 extension.
- Cross-host locks. Locks here are still localhost-bound; combining
  with ADR-0010 or ADR-0016 is future work.
