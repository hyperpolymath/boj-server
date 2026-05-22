-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- FlyMcp.SafeCloud -- Type-safe ABI for fly-mcp cartridge (Fly.io Machines API).
--
-- State machine with dependent-type proofs ensuring only valid transitions
-- can occur at the FFI boundary. Zero unsafe escape hatches.
-- Auth: Bearer token (fly auth token), REST API (https://api.machines.dev/v1/).

module FlyMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication / session state machine
-- ---------------------------------------------------------------------------

||| Authentication and session state for Fly.io Machines API operations.
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate  : ValidTransition Unauthenticated Authenticated
  BeginRateLimit : ValidTransition Authenticated RateLimited
  EndRateLimit  : ValidTransition RateLimited Authenticated
  AuthError     : ValidTransition Unauthenticated Error
  OpError       : ValidTransition Authenticated Error
  RateError     : ValidTransition RateLimited Error
  RecoverAuth   : ValidTransition Error Unauthenticated
  Deauthenticate : ValidTransition Authenticated Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Unauthenticated = 0
sessionStateToInt Authenticated   = 1
sessionStateToInt RateLimited     = 2
sessionStateToInt Error           = 3

||| Decode integer back to session state.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Unauthenticated
intToSessionState 1 = Just Authenticated
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
fly_mcp_can_transition : Int -> Int -> Int
fly_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Unauthenticated, Just Error)           => 1
    (Just Authenticated,   Just Error)           => 1
    (Just RateLimited,     Just Error)           => 1
    (Just Error,           Just Unauthenticated) => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Fly.io Machines API actions
-- ---------------------------------------------------------------------------

||| Actions available on the Fly.io Machines API v1.
public export
data FlyAction
  = ListApps
  | GetApp
  | CreateApp
  | DestroyApp
  | ListMachines
  | GetMachine
  | StartMachine
  | StopMachine
  | ListVolumes
  | CreateVolume
  | ListSecrets
  | SetSecret
  | DeleteSecret
  | ListRegions
  | AllocateIP
  | ReleaseIP

||| Encode action as C-compatible integer for FFI.
export
flyActionToInt : FlyAction -> Int
flyActionToInt ListApps     = 0
flyActionToInt GetApp       = 1
flyActionToInt CreateApp    = 2
flyActionToInt DestroyApp   = 3
flyActionToInt ListMachines = 4
flyActionToInt GetMachine   = 5
flyActionToInt StartMachine = 6
flyActionToInt StopMachine  = 7
flyActionToInt ListVolumes  = 8
flyActionToInt CreateVolume = 9
flyActionToInt ListSecrets  = 10
flyActionToInt SetSecret    = 11
flyActionToInt DeleteSecret = 12
flyActionToInt ListRegions  = 13
flyActionToInt AllocateIP   = 14
flyActionToInt ReleaseIP    = 15

||| Decode integer back to action.
export
intToFlyAction : Int -> Maybe FlyAction
intToFlyAction 0  = Just ListApps
intToFlyAction 1  = Just GetApp
intToFlyAction 2  = Just CreateApp
intToFlyAction 3  = Just DestroyApp
intToFlyAction 4  = Just ListMachines
intToFlyAction 5  = Just GetMachine
intToFlyAction 6  = Just StartMachine
intToFlyAction 7  = Just StopMachine
intToFlyAction 8  = Just ListVolumes
intToFlyAction 9  = Just CreateVolume
intToFlyAction 10 = Just ListSecrets
intToFlyAction 11 = Just SetSecret
intToFlyAction 12 = Just DeleteSecret
intToFlyAction 13 = Just ListRegions
intToFlyAction 14 = Just AllocateIP
intToFlyAction 15 = Just ReleaseIP
intToFlyAction _  = Nothing

||| Whether an action requires Authenticated state.
export
actionRequiresAuth : FlyAction -> Bool
actionRequiresAuth ListRegions = False
actionRequiresAuth _           = True

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol.
public export
data McpTool
  = ToolAuthenticate
  | ToolDeauthenticate
  | ToolStatus
  | ToolInvoke
  | ToolList

||| Check if a tool requires an authenticated session.
export
toolRequiresAuth : McpTool -> Bool
toolRequiresAuth ToolAuthenticate   = False
toolRequiresAuth ToolDeauthenticate = True
toolRequiresAuth ToolStatus         = False
toolRequiresAuth ToolInvoke         = True
toolRequiresAuth ToolList           = False

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 5
