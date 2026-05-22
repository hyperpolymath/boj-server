-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- RokurMcp.SafeGate — Type-safe ABI for the rokur-mcp cartridge.
--
-- Container pre-start secrets gate. Validates that all required secrets
-- are present before allowing a container to start. Delegates to the
-- Rokur sidecar service (Deno, port 9090) for policy evaluation.
-- Never exposes secret values — only presence/absence verdicts.

module RokurMcp.SafeGate

%default total

-- ---------------------------------------------------------------------------
-- Gate state machine
-- ---------------------------------------------------------------------------

||| Gate lifecycle states for container pre-start authorization.
|||
||| - Idle: no authorization request pending.
||| - Checking: secrets presence check in progress.
||| - Allowed: all required secrets present, container may start.
||| - Denied: one or more required secrets missing, container blocked.
||| - Error: policy engine failure (fail-closed = deny).
public export
data GateState = Idle | Checking | Allowed | Denied | Error

||| Proof that a gate state transition is valid.
|||
||| Transition graph:
|||   Idle -> Checking (begin authorization)
|||   Checking -> Allowed (all secrets present)
|||   Checking -> Denied (missing secrets)
|||   Checking -> Error (policy engine failure)
|||   Allowed -> Idle (reset after container started)
|||   Denied -> Idle (reset after denial logged)
|||   Error -> Idle (reset after error handled)
public export
data ValidGateTransition : GateState -> GateState -> Type where
  BeginCheck    : ValidGateTransition Idle Checking
  Approve       : ValidGateTransition Checking Allowed
  Reject        : ValidGateTransition Checking Denied
  Fault         : ValidGateTransition Checking Error
  ResetAllowed  : ValidGateTransition Allowed Idle
  ResetDenied   : ValidGateTransition Denied Idle
  ResetError    : ValidGateTransition Error Idle

-- ---------------------------------------------------------------------------
-- Gate actions
-- ---------------------------------------------------------------------------

||| Actions that can be performed through the MCP rokur interface.
public export
data GateAction
  = AuthorizeStart  -- ^ Request pre-start authorization for a container
  | CheckStatus     -- ^ Query current secrets presence status
  | ReloadSecrets   -- ^ Hot-reload required secrets from environment
  | QueryHealth     -- ^ Liveness check on the Rokur sidecar

||| Whether an action requires the gate to be in a specific state.
||| Health is always available. AuthorizeStart requires Idle.
||| CheckStatus and ReloadSecrets available in Idle or Allowed.
export
actionRequiresIdle : GateAction -> Bool
actionRequiresIdle AuthorizeStart = True
actionRequiresIdle CheckStatus    = False
actionRequiresIdle ReloadSecrets  = False
actionRequiresIdle QueryHealth    = False

-- ---------------------------------------------------------------------------
-- Policy verdict
-- ---------------------------------------------------------------------------

||| Authorization verdict from the policy engine.
||| Secret names are intentionally NEVER exposed — only counts.
public export
record AuthVerdict where
  constructor MkVerdict
  allowed            : Bool
  policy             : String   -- "allow" or "deny"
  code               : String   -- decision reason code
  requiredCount      : Nat
  missingCount       : Nat
  policyEngine       : String   -- "builtin" or "external"

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding — gate state
-- ---------------------------------------------------------------------------

export
gateStateToInt : GateState -> Int
gateStateToInt Idle     = 0
gateStateToInt Checking = 1
gateStateToInt Allowed  = 2
gateStateToInt Denied   = 3
gateStateToInt Error    = 4

export
intToGateState : Int -> Maybe GateState
intToGateState 0 = Just Idle
intToGateState 1 = Just Checking
intToGateState 2 = Just Allowed
intToGateState 3 = Just Denied
intToGateState 4 = Just Error
intToGateState _ = Nothing

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding — gate action
-- ---------------------------------------------------------------------------

export
gateActionToInt : GateAction -> Int
gateActionToInt AuthorizeStart = 0
gateActionToInt CheckStatus    = 1
gateActionToInt ReloadSecrets  = 2
gateActionToInt QueryHealth    = 3

export
intToGateAction : Int -> Maybe GateAction
intToGateAction 0 = Just AuthorizeStart
intToGateAction 1 = Just CheckStatus
intToGateAction 2 = Just ReloadSecrets
intToGateAction 3 = Just QueryHealth
intToGateAction _ = Nothing

-- ---------------------------------------------------------------------------
-- C-ABI transition validator
-- ---------------------------------------------------------------------------

export
rokur_mcp_can_transition : Int -> Int -> Int
rokur_mcp_can_transition from to =
  case (intToGateState from, intToGateState to) of
    (Just Idle,     Just Checking) => 1  -- BeginCheck
    (Just Checking, Just Allowed)  => 1  -- Approve
    (Just Checking, Just Denied)   => 1  -- Reject
    (Just Checking, Just Error)    => 1  -- Fault
    (Just Allowed,  Just Idle)     => 1  -- ResetAllowed
    (Just Denied,   Just Idle)     => 1  -- ResetDenied
    (Just Error,    Just Idle)     => 1  -- ResetError
    _                              => 0

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

public export
data McpTool
  = ToolAuthorizeStart   -- ^ rokur/authorize-start
  | ToolCheckStatus      -- ^ rokur/status
  | ToolReloadSecrets    -- ^ rokur/reload
  | ToolHealth           -- ^ rokur/health

export
toolCount : Nat
toolCount = 4
