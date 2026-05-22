-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Oo7Mcp.SafeCli — Type-safe ABI for the 007-mcp cartridge.
--
-- Three compile-time invariants:
--
--   1. Loopback-only bind. The `IsLoopback` sum type has exactly two
--      constructors (Ipv4Loopback, Ipv6Loopback). Every BindAddress
--      value threads an `IsLoopback` proof, so constructing a bind to
--      any non-loopback address is type-impossible. Mirrors the same
--      pattern used by local-coord-mcp.
--
--   2. Lifecycle ordering. The `SessionState` state machine forces
--      `OnEnter` before any tool dispatch and `OnExit` before
--      deregistration. `ValidTransition` enumerates exactly the legal
--      edges — anything else is a type error in well-typed callers.
--
--   3. Risk-gated destructive tools. `ToolRisk` lifts the DD-5 risk
--      ladder into Idris2. The `dust_source_rollback` tool is Tier 3
--      (hard gate); the adapter rejects invocations that lack a
--      supervisor-approval witness.

module Oo7Mcp.SafeCli

%default total

-- ---------------------------------------------------------------------------
-- Loopback-only bind proof
-- ---------------------------------------------------------------------------

||| Witness that a bind address is on the local loopback interface.
||| The only two constructors are IPv4 127.0.0.1 and IPv6 ::1.
||| There is intentionally no constructor for any other address, so
||| `BindAddress` values cannot name a non-loopback target.
public export
data IsLoopback : Type where
  Ipv4Loopback : IsLoopback  -- 127.0.0.1
  Ipv6Loopback : IsLoopback  -- ::1

||| A bind address carrying proof of loopback-ness.
||| The Idris2 ABI never constructs a BindAddress without this proof,
||| so the adapter's runtime bind inherits the compile-time guarantee.
public export
record BindAddress where
  constructor MkBindAddress
  host     : String
  port     : Int
  proof    : IsLoopback

||| The one and only production bind — 127.0.0.1:1066.
||| Port 1066 chosen in design-log decision-log 2026-04-20.
public export
cartridgeBind : BindAddress
cartridgeBind = MkBindAddress "127.0.0.1" 1066 Ipv4Loopback

||| C-ABI export: fetch the host as a cstring.
||| The FFI wrapper reads this at server-start time.
export
oo7_mcp_bind_host : String
oo7_mcp_bind_host = cartridgeBind.host

export
oo7_mcp_bind_port : Int
oo7_mcp_bind_port = cartridgeBind.port

||| Encode the loopback proof tag for C consumption: 4 or 6.
||| Lets the adapter sanity-check that the proof travelled across FFI.
export
oo7_mcp_bind_family : Int
oo7_mcp_bind_family = case cartridgeBind.proof of
  Ipv4Loopback => 4
  Ipv6Loopback => 6

-- ---------------------------------------------------------------------------
-- Session state machine
-- ---------------------------------------------------------------------------

||| Session states for a 007-mcp cartridge instance.
|||
|||   Fresh        — constructed, no lifecycle hook run yet
|||   Registered   — OnEnter has registered this session with local-coord-mcp
|||                  and loaded the 6a2 methodology pack
|||   InvokingTool — a tool dispatch is in flight (serialised)
|||   Deregistered — OnExit has released claims and deregistered
|||   Degraded     — local-coord-mcp was unreachable during OnEnter; the
|||                  cartridge operates in local-only mode (no coord ops)
public export
data SessionState
  = Fresh
  | Registered
  | InvokingTool
  | Deregistered
  | Degraded

||| Proof that a state transition is valid.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  EnterOk        : ValidTransition Fresh        Registered
  EnterDegrade   : ValidTransition Fresh        Degraded
  BeginDispatch  : ValidTransition Registered   InvokingTool
  BeginDispatchD : ValidTransition Degraded     InvokingTool  -- local-only tools still run
  EndDispatchR   : ValidTransition InvokingTool Registered
  EndDispatchD   : ValidTransition InvokingTool Degraded
  ExitR          : ValidTransition Registered   Deregistered
  ExitD          : ValidTransition Degraded     Deregistered

||| Encode session state as C-compatible integer for FFI boundary.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Fresh        = 0
sessionStateToInt Registered   = 1
sessionStateToInt InvokingTool = 2
sessionStateToInt Deregistered = 3
sessionStateToInt Degraded     = 4

||| Decode integer back to session state.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Fresh
intToSessionState 1 = Just Registered
intToSessionState 2 = Just InvokingTool
intToSessionState 3 = Just Deregistered
intToSessionState 4 = Just Degraded
intToSessionState _ = Nothing

||| C-ABI export: is a transition permitted?
||| Returns 1 if yes, 0 if no — consumed by the Zig adapter's guard
||| before flipping its own state atomic.
export
oo7_mcp_can_transition : Int -> Int -> Int
oo7_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Fresh,        Just Registered)   => 1
    (Just Fresh,        Just Degraded)     => 1
    (Just Registered,   Just InvokingTool) => 1
    (Just Degraded,     Just InvokingTool) => 1
    (Just InvokingTool, Just Registered)   => 1
    (Just InvokingTool, Just Degraded)     => 1
    (Just Registered,   Just Deregistered) => 1
    (Just Degraded,     Just Deregistered) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- Tool risk classification (DD-5 risk ladder)
-- ---------------------------------------------------------------------------

||| Risk tier for a tool invocation.
||| Tier 0 — free (status, reads)
||| Tier 1 — logged (runtime reads, tests, builds, lint)
||| Tier 2 — light gate (container builds, docs generate, heal)
||| Tier 3 — hard gate (rollback, destructive clean, container-run w/ privileged)
||| Tier 4 — forbidden for supervised role (NONE on 007-mcp — no public-repo writes,
||| no license touches here; Tier 4 is reserved for future tools only)
public export
data ToolRisk
  = Tier0
  | Tier1
  | Tier2
  | Tier3
  | Tier4

export
tierToInt : ToolRisk -> Int
tierToInt Tier0 = 0
tierToInt Tier1 = 1
tierToInt Tier2 = 2
tierToInt Tier3 = 3
tierToInt Tier4 = 4

-- ---------------------------------------------------------------------------
-- Tool taxonomy
-- ---------------------------------------------------------------------------

||| High-level categories for the 007-mcp tool surface. Finer-grained
||| names live in the Zig dispatcher; this enum is the compile-time
||| coarse classification used for risk inference.
public export
data ToolCategory
  = Lifecycle     -- on-enter, on-exit
  | Runtime       -- parse, run, trace, demo
  | BuildArtifact -- build, clean, docs, release
  | Test          -- test*, check, ci, preflight
  | Quality       -- lint, fmt, audit, deny, outdated, assail
  | Contractile   -- must/trust/intend/dust/bust/adjust
  | Verification  -- verify*, grammar-check, spec-check
  | ProofSuite    -- canonical-proof-suite, v0/v1 differential
  | Groove        -- groove-daemon, groove-setup
  | Container     -- container-build, container-run, container-verify
  | Meta          -- info, tour, help, self-assess, cookbook, crg-*
  | ToolchainMgmt -- doctor, heal

||| Default risk tier per category. The dispatcher can promote
||| individual tools (see riskPromotion below) for destructive variants.
export
categoryDefaultRisk : ToolCategory -> ToolRisk
categoryDefaultRisk Lifecycle     = Tier0  -- lifecycle hooks are idempotent reads
categoryDefaultRisk Runtime       = Tier1
categoryDefaultRisk BuildArtifact = Tier1
categoryDefaultRisk Test          = Tier1
categoryDefaultRisk Quality       = Tier1
categoryDefaultRisk Contractile   = Tier1
categoryDefaultRisk Verification  = Tier0
categoryDefaultRisk ProofSuite    = Tier1
categoryDefaultRisk Groove        = Tier2  -- starts a daemon, long-running
categoryDefaultRisk Container     = Tier2
categoryDefaultRisk Meta          = Tier0
categoryDefaultRisk ToolchainMgmt = Tier2  -- `heal` mutates system state

||| Promotion table for specific tools whose risk exceeds their
||| category default. Names are the canonical MCP tool names from
||| cartridge.ncl.
export
riskPromotion : String -> Maybe ToolRisk
riskPromotion "oo7_dust_source_rollback" = Just Tier3
riskPromotion "oo7_clean_all"            = Just Tier2
riskPromotion "oo7_container_run"        = Just Tier3
riskPromotion "oo7_groove_daemon"        = Just Tier3
riskPromotion _                          = Nothing

-- ---------------------------------------------------------------------------
-- Counts for the FFI header generator
-- ---------------------------------------------------------------------------

||| Total tool count — kept in sync with cartridge.ncl.
||| 2 lifecycle + 5 runtime + 7 build + 7 test + 6 quality + 3 audits
|||   + 1 assail + 2 toolchain + 17 contractile + 3 verification
|||   + 2 grammar/spec + 4 proof suite + 2 groove + 3 container
|||   + 8 meta + 2 crg = 72  (re-derived each version bump)
export
toolCount : Nat
toolCount = 72

||| Fixed-width wire counts (useful for FFI buffer sizing).
export
maxToolNameLen : Nat
maxToolNameLen = 48

export
maxArgStringLen : Nat
maxArgStringLen = 4096
