<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
# Haiku scout — next-pass lint / trivial-fix prompt

Reusable template for a fast Haiku scouting pass over a concrete file list
after a coord task lands. Paired with the multi-agent coord flow
(Opus supervises, Haiku scouts, Sonnet/Opus writes).

## Template

```
Haiku scout, scope = <exact file list for the step>

1. Confirm each file compiles in isolation
   (cargo check --lib / julia -e / zig build-obj / node --check).
2. Scan for:
   - unused imports
   - dead code
   - `todo!()` / FIXME / XXX
   - orphan type references
   - stale doc comments referring to renamed symbols
   - broken `mod.rs` exports
3. Trivially fix:
   - unused imports (remove)
   - obvious typos in comments
   - unused `_var` renames
4. DO NOT fix — FLAG to me:
   - any TODO with semantic content (may be load-bearing)
   - anything requiring judgement about intent
   - any cross-module change
5. Report: <20 lines. Green-light or list of blockers.
```

## Invocation guidance

- Scope must be an **exact file list** (no globs, no "the changed files")
  so the scout has a finite surface.
- Compile-in-isolation check runs **before** the scan — a file that does
  not parse on its own will generate too many false positives to be
  useful.
- Category 4 (FLAG, don't fix) is the firewall. `local-coord-mcp`
  treats this as a tier-1 envelope from `apprentice` role: visible but
  gated on master review before any change lands.
- The `<20 lines` cap keeps the report digestible in the master's
  next batch-review slot.

## Coord integration

When run under the `boj-server/cartridges/local-coord-mcp` bus, the
scout should:

1. `coord_register` as `kind=claude`, `variant=haiku-4.5`,
   `declared_affinities=["scout", "lint"]`.
2. `coord_claim_task` with `task_difficulty=routine`,
   `dispatch_preference=auto`.
3. For each flagged item in step 4, emit `coord_send_gated` with
   `risk_tier=1` (warn) — goes straight into the master's quarantine.
4. On completion, `coord_report_outcome` with the observed tag and
   outcome so the track-record aggregates reflect scout accuracy.
