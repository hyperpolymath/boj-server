# Coord-MCP Multi-Agent Coordination — State of Things

**Where we are now, in relation to the forward vision.** Complements
`COORD-MCP-TODO.md` (actionable backlog) and `COORD-MCP-DESIGN-LOG.md`
(full design rationale + DD-1..DD-38 + appendices A–M).

Last updated: 2026-04-20.

---

## Vision (one paragraph)

A localhost message bus (`boj-server/cartridges/local-coord-mcp`) lets
multiple AI agents on the same machine discover each other, exchange
typed messages, claim tasks without collision, and operate under a
supervision model where **Opus co-supervises with the user**. The user
stays single-threaded: they talk to Opus in the main terminal; other
agents (Claude Sonnet/Haiku, Codex, Gemini, Vibe, GPT-n, Mistral) work
in their own windows and reach the user only through Opus, who dedupes,
synthesises, and rejects confabulation. Non-Claude agents run under a
Byzantine-safe firewall that contains their failure modes without
stopping them from contributing. v1 is hermetically local; v2 adds
federation only for joint IDApTIK/ASS sessions with the user's son,
with an explicit authoritative-site designation per project to prevent
mission drift.

## The ladder (how trust and awareness scale)

| Axis | Values | Gate |
|------|--------|------|
| **Trust role** (1 per peer, gated) | `master` / `journeyman` / `apprentice` | Master via `BOJ_MASTER_TOKEN` env secret; other roles self-declared |
| **Risk tier** (per message) | 0 (status/query) → 4 (force-push, license, always-private) | Tier 2+ from apprentice → quarantine; Tier 4 schema-level forbidden for apprentice |
| **Awareness posture** (per message) | drone / narrow / local / strategic / full | `context_fetch_id` REQUIRED for Tier 2+; no blind risky edits |
| **Capability** (advertised, multiple) | class ∈ {reasoner, coder, mathematician, scribe, proofsmith, reader, jester}; tier A/B/C; `prover_strengths` map | Free-form opt-in; informs router; track-record dominates over time |
| **Model identity** | `client_kind` ∈ {claude, gemini, copilot, custom, openai, mistral}; `variant` free-form | Register-time, cold-start metadata for the router |

## What's built today

### Layer 1 — Transport
- Loopback-only Zig REST server on port 7745.
- Idris2 `IsLoopback` type has exactly two constructors; bind to
  non-loopback is type-impossible. (DD-1, P-00.)

### Layer 2 — Identity
- `coord_register(client_kind, role_hint, context)` → `peer_id` of form
  `<kind>-<4hex>[@<context>]` + 128-bit CSPRNG session token. (DD-2, DD-3.)
- Max 16 peers per box.
- Role rename **done** (DD-32): master/journeyman/apprentice. Old
  `supervisor/executor/supervised` accepted as aliases for one release.

### Layer 3 — Envelope
- 18 typed `op_kind`s. 5-level risk ladder. Nickel contracts validate
  shape at the bridge before the Zig adapter. (DD-4, DD-5, DD-16, DD-17.)
- Fields landed: `sender_confidence`, `sender_reasoning`,
  `context_fetch_id`, `difficulty_hint`, `dispatch_preference`,
  `task_difficulty`, `tier_override_reason`, `urgent_direct`,
  `ack_required`, `ttl_seconds`. (DDs 4/5/9/10/15/30/36.)
- Prover routing by tag convention: `proof:lean4`/`agda`/`idris2`/`rocq`/`tla`. (DD-37.)

### Layer 4 — Supervision
- Three roles gated; master role behind env secret. (DD-6, DD-7, DD-19.)
- Quarantine queue `MAX_QUARANTINE=32` hot cache + server-origin entries
  for reassignment suggestions. (DD-21, Task #14.)
- `coord_review` / `approve` / `reject` tools. Apprentice cannot set
  `urgent_direct`. (DD-12, Task #6.)
- Sanity auto-promote: `git push`/`rm -rf`/license mentions auto-bump
  to Tier 3 regardless of declared tier. (DD-14.)
- Tier 4 schema-level forbidden for apprentice: force-push, license
  touches, always-private-repos. (DD-13.)
- Rejection cooldown per `client_kind` — 5 rejects / 10 min = 30 s.

### Layer 5 — Durability
- In-tree `coord_durability.zig` — append-only log + CRC-trailed records
  + typed helpers (`logPeerAdd`, `logInboxPush`, …). Restart-safe replay.
  State at `$BOJ_COORD_STATE_DIR` (default `$XDG_STATE_HOME/boj-server/coord/`).
  Per-box, per DD-23. (DD-31, Task #7.)
- Benchmarks: ~4.7 µs append, ~9 µs durable round-trip, ~110k ops/sec
  durable, ~9M ops/sec no-durability.
- 27 Zig + 41 Deno E2E tests green. Panic-attack assail clean.
- **Task #7b deferred**: swap backend to `verisimdb-mcp` FFI once it's
  real (currently all stubs). Typed helpers stay as the stable seam.

### Layer 6 — Cartridges
- **007-mcp cartridge (007-lang)**: 72 MCP tools exposing full `oo7`
  CLI, Idris2 `IsLoopback` proof at `127.0.0.1:1066`, Zig FFI + HTTP
  adapter, Nickel manifest. On-enter/on-exit hooks (register, read
  STATE/methodology, release claims). `bust/` (16 hard-stops) +
  `adjust/` (8 drift-corrections). Memory auto-lift with real parser
  (5 unit tests, `MAX_HITS=8`, graceful degrade). (Tasks #9–#12.)
- **k9 moved to `svc/k9/`** (ADR-001 2026-04-18). `contractiles/` is
  pure 6-verb set; k9 is not a contractile.

### Byzantine safety — mechanism status

| Mechanism | Status | Catches |
|-----------|--------|---------|
| 1. Hash chain per sender (`prev_msg_hash`) | **Pending P1** | Retroactive rewriting |
| 2. M-of-N attestation for Tier 2+ from apprentice | Designed (DD-8); implementation pending | Unilateral bad commits |
| 3. Watchdog claims with TTL + heartbeat | **Pending P1** (DD-20) | Claim-squatting |
| 4. Content sanity gate | **Pending P1** (DD-14) | Confabulation + tier underclaiming |
| 5. Tamper-evident audit log | **Partial** — durability done; explicit envelope-audit index pending | Forensics / f+1 case |

### Self-assessment — layer status

- Layer A (static affinity, register-time) — **done** (DD-34 landed as Task #34 pending, but declared affinities already accepted).
- Layer B (per-claim `confidence` + `reasoning`) — **done** (DD-9, Task #15).
- Layer C (server-computed `effective_affinity` from track record) — **done** (DD-9, Task #13).
- Layer D (drift detector: confidence ≫ track record → flag) — **pending P1**.

## Architectural spine — decisions taken

38 decisions, DD-1..DD-38. Highlights:

- **DD-1**: Loopback-only v1. Compile-time proven.
- **DD-8**: 5 Byzantine mechanisms, not consensus. BFT's useful half
  without the round-trip cost.
- **DD-9**: Self-assessment is 4 layers; static declaration is never
  trusted alone.
- **DD-10**: `context_fetch_id` required for Tier 2+. Blast-radius-scaled
  awareness; forces read-before-risky-write.
- **DD-11**: Summary-vs-raw context gated by role. Apprentices never see
  raw state (prevents hallucinated connections).
- **DD-12**: `fyi`/`clarify`/`blocker`/`urgent_direct` routing. User has
  one locus (main terminal, Opus); apprentices firewalled from
  interrupting.
- **DD-15**: Hybrid dispatch — Opus seeds + peers self-claim by affinity.
- **DD-18**: GitHub only. Push `origin`; no other forges directly.
- **DD-22**: v2 federation uses authoritative-site model (one site holds
  primacy per project). Motivated by IDApTIK drift, not credit load.
- **DD-23**: VeriSimDB per-pattern: coord = per-box; 007 repo data =
  per-project; track record = per-box; memory auto-lift = per-project.
- **DD-29**: Peer crash+restart = fresh chain as new peer; old chain
  preserved as audit echo anchor. Epistemic honesty.
- **DD-31**: Task #7 durability shipped as in-tree `coord_durability.zig`
  because `verisimdb-mcp` FFI is all stubs. Stable seam for later swap.
- **DD-32**: Role rename to master/journeyman/apprentice (craft guild).
  Backward-compat shims for one release.
- **DD-33–37**: Multi-model extension (Appendix M) — client_kind +
  variant, capability class/tier/prover_strengths, master handoff,
  difficulty hint, prover tag convention.
- **DD-38**: Split gatekeeper (trust) from scheduler (dispatch) — flagged
  for future, deferred.

## Adjacent work (not core coord but in this orbit)

- **Echidna L3 live-prover CI** — Wave-1 (9 Tier-1 backends, every PR)
  and Wave-2 (10 Tier-2 backends, nightly) **done** 2026-04-19. Wave-3
  (9 Tier-3 backends, weekly) needs per-backend Containerfiles; Wave-4
  (19 Tier-4 backends, quarterly) scaffold only. Handover hints in
  `verification-ecosystem/echidna/.machine_readable/6a2/STATE.a2ml`.
- **Echidna Chapel FFI** — `cargo build --features chapel` now
  self-links against bundled Zig stubs (`-Dstubs=true` default);
  real-Chapel CI job still outstanding.
- **Tamarin/ProVerif in echidna** — fully wired (592 + 799 LoC Rust
  backends, registered in `ProverFactory`, 4 unit tests). Was stale-listed
  as "planned" — corrected.

## Interaction model (how the user uses this)

Main terminal, Opus as chief-of-staff.

- Apprentice peers never get a direct line to the user. Questions filter
  through Opus.
- Supervisor (master) + journeyman peers can flag `urgent_direct` — breaks
  into Opus's output inline.
- Three urgency levels baked into `op_kind`: `blocker` (surface inline),
  `clarify` (batch), `fyi` (log only).
- User can always pull: "what are all agents doing?" → Opus calls
  `coord_list_peers` + synthesises. "Kill Gemini's current task" → Opus
  sends `release` on its behalf.
- Escape hatch: visit another agent's terminal directly. Default is:
  main terminal, single locus.

## Deferred by phase

| Phase | Trigger | Content |
|-------|---------|---------|
| 1b | Now — refinements during current buildout | Hash chain, sanity gate, watchdog, warn-drift broadcast, quarantine spill, audit-echo, drift detector, coord_health metrics |
| 2 | After Task #8 E2E (done) validates imperative version | Idris2 session types for supervisor/attestation choreography; deontic/dyadic types for supervision rules |
| 3 | After Phase 2 lands | Agda echo-types formalisation of audit/summary/hash-chain; tropical-types modeling lens; rename `context_fetch_id` → `knowledge_witness` |
| 4 | First joint IDApTIK/ASS session with son | Envelope v2 (`site_id`, `federation.*`); authoritative-site model; SDP + Stapeln + HTTP capability gateway; primacy handoff ceremony; Umoja federation integration |

## Agreed decisions this session (ratified 2026-04-20)

Captured in `COORD-MCP-TODO.md` under Decisions. Summary:

- **D1**: Refactor `DataExpr` (split pure/control); do not paper over with variance.
- **D2**: `.machine_readable/6a2/` is canonical for all SCM files; remove root copies after diff/merge.
- **D3**: Wait on `just cartridge-install` until coord-mcp Tasks #33/#34 ship.
- **D4**: Revert canonical-proof-suite probe-timing sidecars in 007-lang.
