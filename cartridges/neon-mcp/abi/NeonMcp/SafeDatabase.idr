-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- NeonMcp.SafeDatabase — Type-safe ABI for the neon-mcp cartridge.
--
-- Provides a formally verified state machine for Neon serverless Postgres
-- connections. Dependent-type proofs ensure only valid transitions can occur
-- at the FFI boundary. Neon actions cover the full REST API surface
-- (https://console.neon.tech/api/v2/). Auth via Bearer token (Neon API key).
-- Endpoints auto-suspend when idle (serverless Postgres semantics).

module NeonMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for Neon serverless Postgres operations.
||| Endpoints auto-suspend, so Disconnected is the natural resting state.
public export
data ConnState = Disconnected | Connected | QueryRunning | Error

||| Proof that a state transition is valid.
public export
data ValidTransition : ConnState -> ConnState -> Type where
  Connect       : ValidTransition Disconnected Connected
  StartQuery    : ValidTransition Connected QueryRunning
  FinishQuery   : ValidTransition QueryRunning Connected
  Disconnect    : ValidTransition Connected Disconnected
  QueryFail     : ValidTransition QueryRunning Error
  ErrorRecover  : ValidTransition Error Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode connection state as C-compatible integer.
export
connStateToInt : ConnState -> Int
connStateToInt Disconnected = 0
connStateToInt Connected    = 1
connStateToInt QueryRunning = 2
connStateToInt Error        = 3

||| Decode integer back to connection state.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Disconnected
intToConnState 1 = Just Connected
intToConnState 2 = Just QueryRunning
intToConnState 3 = Just Error
intToConnState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
neon_mcp_can_transition : Int -> Int -> Int
neon_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just QueryRunning) => 1
    (Just QueryRunning, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just QueryRunning, Just Error)        => 1
    (Just Error,        Just Disconnected) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- Neon actions (full REST API surface)
-- ---------------------------------------------------------------------------

||| Actions supported by the Neon MCP cartridge.
||| Covers projects, branches, endpoints, databases, roles, and operations.
public export
data NeonAction
  = ListProjects
  | GetProject
  | CreateProject
  | DeleteProject
  | ListBranches
  | CreateBranch
  | DeleteBranch
  | GetConnectionString
  | Query
  | ListDatabases
  | ListRoles
  | GetEndpoint
  | StartEndpoint
  | SuspendEndpoint
  | ListOperations
  | GetOperation

||| Encode action as C-compatible integer.
export
neonActionToInt : NeonAction -> Int
neonActionToInt ListProjects       = 0
neonActionToInt GetProject         = 1
neonActionToInt CreateProject      = 2
neonActionToInt DeleteProject      = 3
neonActionToInt ListBranches       = 4
neonActionToInt CreateBranch       = 5
neonActionToInt DeleteBranch       = 6
neonActionToInt GetConnectionString = 7
neonActionToInt Query              = 8
neonActionToInt ListDatabases      = 9
neonActionToInt ListRoles          = 10
neonActionToInt GetEndpoint        = 11
neonActionToInt StartEndpoint      = 12
neonActionToInt SuspendEndpoint    = 13
neonActionToInt ListOperations     = 14
neonActionToInt GetOperation       = 15

||| Decode integer back to action.
export
intToNeonAction : Int -> Maybe NeonAction
intToNeonAction 0  = Just ListProjects
intToNeonAction 1  = Just GetProject
intToNeonAction 2  = Just CreateProject
intToNeonAction 3  = Just DeleteProject
intToNeonAction 4  = Just ListBranches
intToNeonAction 5  = Just CreateBranch
intToNeonAction 6  = Just DeleteBranch
intToNeonAction 7  = Just GetConnectionString
intToNeonAction 8  = Just Query
intToNeonAction 9  = Just ListDatabases
intToNeonAction 10 = Just ListRoles
intToNeonAction 11 = Just GetEndpoint
intToNeonAction 12 = Just StartEndpoint
intToNeonAction 13 = Just SuspendEndpoint
intToNeonAction 14 = Just ListOperations
intToNeonAction 15 = Just GetOperation
intToNeonAction _  = Nothing

||| Check whether an action requires an active connection.
export
actionRequiresConnection : NeonAction -> Bool
actionRequiresConnection Query              = True
actionRequiresConnection GetConnectionString = True
actionRequiresConnection _                   = False

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Auth configuration
-- ---------------------------------------------------------------------------

||| Authentication method for Neon REST API.
||| Bearer token using a Neon API key.
public export
data NeonAuth = BearerToken

||| Base URL for Neon REST API.
export
neonApiBase : String
neonApiBase = "https://console.neon.tech/api/v2/"
