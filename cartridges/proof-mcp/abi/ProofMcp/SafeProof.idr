-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| ProofMcp.SafeProof: Formally verified proof verification operations.
|||
||| Cartridge: proof-mcp
||| Matrix cell: Proof domain x {MCP, LSP} protocols
|||
||| This module defines type-safe proof verification operations with a
||| verification state machine that prevents:
|||   - Verification without a loaded proof obligation
|||   - Retrieving results from an incomplete verification
|||   - Double-loading proof obligations
|||
||| Designed to integrate with the echidna/theorem-proving domain.
module ProofMcp.SafeProof

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Proof Verification State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Proof verification lifecycle states.
||| A verification progresses: Idle -> Loading -> Verifying -> Verified/Failed -> Idle
public export
data ProofState = Idle | Loading | Verifying | Verified | Failed

||| Equality for proof states.
public export
Eq ProofState where
  Idle      == Idle      = True
  Loading   == Loading   = True
  Verifying == Verifying = True
  Verified  == Verified  = True
  Failed    == Failed    = True
  _         == _         = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : ProofState -> ProofState -> Type where
  Load       : ValidTransition Idle Loading
  StartProof : ValidTransition Loading Verifying
  Succeed    : ValidTransition Verifying Verified
  Fail       : ValidTransition Verifying Failed
  ResetOk    : ValidTransition Verified Idle
  ResetFail  : ValidTransition Failed Idle
  CancelLoad : ValidTransition Loading Idle

||| Runtime transition validator.
public export
canTransition : ProofState -> ProofState -> Bool
canTransition Idle      Loading   = True
canTransition Loading   Verifying = True
canTransition Verifying Verified  = True
canTransition Verifying Failed    = True
canTransition Verified  Idle      = True
canTransition Failed    Idle      = True
canTransition Loading   Idle      = True
canTransition _         _         = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Proof Backend Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported proof backends / theorem provers.
public export
data ProofBackend
  = Z3           -- SMT solver
  | CVC5         -- SMT solver
  | Lean         -- Lean 4 theorem prover
  | Coq          -- Coq proof assistant
  | Agda         -- Agda dependently typed language
  | Isabelle     -- Isabelle/HOL
  | Idris2       -- Idris2 (self-hosted verification)
  | Custom String -- User-defined backend

||| C-ABI encoding.
public export
backendToInt : ProofBackend -> Int
backendToInt Z3           = 1
backendToInt CVC5         = 2
backendToInt Lean         = 3
backendToInt Coq          = 4
backendToInt Agda         = 5
backendToInt Isabelle     = 6
backendToInt Idris2       = 7
backendToInt (Custom _)   = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Proof Obligation Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Proof obligation classification.
||| Automated obligations can be discharged by SMT solvers.
||| Interactive obligations require human-guided proof.
public export
data ObligationKind = Automated | Interactive

||| A proof obligation with classification.
public export
record ProofObligation where
  constructor MkObligation
  obligationId : String
  kind         : ObligationKind
  backend      : ProofBackend
  sourceFile   : String

||| Verification result status.
public export
data VerifyResult
  = ProofComplete Nat      -- Number of goals discharged
  | ProofIncomplete Nat    -- Goals remaining
  | ProofError String      -- Error with message

-- ═══════════════════════════════════════════════════════════════════════════
-- Session Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A proof verification session with tracked state.
public export
record ProofSession where
  constructor MkProofSession
  sessionId : String
  backend   : ProofBackend
  state     : ProofState

||| Proof that a session has a verified result (safe to retrieve).
public export
data IsVerified : ProofSession -> Type where
  VerifiedSession : (s : ProofSession) ->
                    (state s = Verified) ->
                    IsVerified s

||| Proof that a cartridge state machine is unbreakable.
||| Every state has at least one valid outgoing transition,
||| ensuring the system never gets stuck.
public export
data IsUnbreakable : Type where
  MkUnbreakable :
    (idleOut      : canTransition Idle Loading = True) ->
    (loadOut      : canTransition Loading Verifying = True) ->
    (verifyOk     : canTransition Verifying Verified = True) ->
    (verifyFail   : canTransition Verifying Failed = True) ->
    (verifiedOut  : canTransition Verified Idle = True) ->
    (failedOut    : canTransition Failed Idle = True) ->
    (cancelLoad   : canTransition Loading Idle = True) ->
    IsUnbreakable

||| Witness that the proof state machine is unbreakable.
public export
proofMachineUnbreakable : IsUnbreakable
proofMachineUnbreakable = MkUnbreakable Refl Refl Refl Refl Refl Refl Refl

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolInit           -- Initialise proof session
  | ToolLoad           -- Load a proof obligation
  | ToolVerify         -- Run verification
  | ToolGetResult      -- Retrieve verification result
  | ToolReset          -- Reset session to idle
  | ToolListBackends   -- List available proof backends
  | ToolStatus         -- Session health check

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolInit         = "proof/init"
toolName ToolLoad         = "proof/load"
toolName ToolVerify       = "proof/verify"
toolName ToolGetResult    = "proof/get-result"
toolName ToolReset        = "proof/reset"
toolName ToolListBackends = "proof/list-backends"
toolName ToolStatus       = "proof/status"

||| Which tools require an active session.
public export
requiresSession : McpTool -> Bool
requiresSession ToolInit         = False
requiresSession ToolListBackends = False
requiresSession _                = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Proof state to integer.
public export
proofStateToInt : ProofState -> Int
proofStateToInt Idle      = 0
proofStateToInt Loading   = 1
proofStateToInt Verifying = 2
proofStateToInt Verified  = 3
proofStateToInt Failed    = 4

||| FFI: Validate a state transition.
export
proof_can_transition : Int -> Int -> Int
proof_can_transition from to =
  let fromState = case from of
                    0 => Idle
                    1 => Loading
                    2 => Verifying
                    3 => Verified
                    _ => Failed
      toState = case to of
                  0 => Idle
                  1 => Loading
                  2 => Verifying
                  3 => Verified
                  _ => Failed
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires an active session.
export
proof_tool_requires_session : Int -> Int
proof_tool_requires_session 1 = 0  -- ToolInit
proof_tool_requires_session 6 = 0  -- ToolListBackends
proof_tool_requires_session _ = 1  -- All others require session
