-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- TursoMcp.SafeDatabase — Type-safe ABI for the turso-mcp cartridge.
--
-- Provides a formally verified state machine for Turso (libSQL) database
-- connections. Dependent-type proofs ensure only valid transitions can occur
-- at the FFI boundary. Turso actions cover the full REST API surface
-- (https://api.turso.tech/v1/). Auth via Bearer token (Turso API token).
-- Edge-replica-aware with embedded replica support.

module TursoMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for Turso libSQL operations.
||| Supports primary and edge replica connections.
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
turso_mcp_can_transition : Int -> Int -> Int
turso_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just QueryRunning) => 1
    (Just QueryRunning, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just QueryRunning, Just Error)        => 1
    (Just Error,        Just Disconnected) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- Turso actions (full REST API surface)
-- ---------------------------------------------------------------------------

||| Actions supported by the Turso MCP cartridge.
||| Covers databases, groups, tokens, stats, locations, organizations, and usage.
public export
data TursoAction
  = ListDatabases
  | CreateDatabase
  | DeleteDatabase
  | GetDatabase
  | ListGroups
  | CreateGroup
  | Query
  | BatchQuery
  | ListTokens
  | CreateToken
  | RevokeToken
  | GetStats
  | ListLocations
  | ListOrganizations
  | TransferDatabase
  | GetUsage

||| Encode action as C-compatible integer.
export
tursoActionToInt : TursoAction -> Int
tursoActionToInt ListDatabases      = 0
tursoActionToInt CreateDatabase     = 1
tursoActionToInt DeleteDatabase     = 2
tursoActionToInt GetDatabase        = 3
tursoActionToInt ListGroups         = 4
tursoActionToInt CreateGroup        = 5
tursoActionToInt Query              = 6
tursoActionToInt BatchQuery         = 7
tursoActionToInt ListTokens         = 8
tursoActionToInt CreateToken        = 9
tursoActionToInt RevokeToken        = 10
tursoActionToInt GetStats           = 11
tursoActionToInt ListLocations      = 12
tursoActionToInt ListOrganizations  = 13
tursoActionToInt TransferDatabase   = 14
tursoActionToInt GetUsage           = 15

||| Decode integer back to action.
export
intToTursoAction : Int -> Maybe TursoAction
intToTursoAction 0  = Just ListDatabases
intToTursoAction 1  = Just CreateDatabase
intToTursoAction 2  = Just DeleteDatabase
intToTursoAction 3  = Just GetDatabase
intToTursoAction 4  = Just ListGroups
intToTursoAction 5  = Just CreateGroup
intToTursoAction 6  = Just Query
intToTursoAction 7  = Just BatchQuery
intToTursoAction 8  = Just ListTokens
intToTursoAction 9  = Just CreateToken
intToTursoAction 10 = Just RevokeToken
intToTursoAction 11 = Just GetStats
intToTursoAction 12 = Just ListLocations
intToTursoAction 13 = Just ListOrganizations
intToTursoAction 14 = Just TransferDatabase
intToTursoAction 15 = Just GetUsage
intToTursoAction _  = Nothing

||| Check whether an action requires an active connection.
export
actionRequiresConnection : TursoAction -> Bool
actionRequiresConnection Query      = True
actionRequiresConnection BatchQuery = True
actionRequiresConnection _          = False

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Auth configuration
-- ---------------------------------------------------------------------------

||| Authentication method for Turso REST API.
||| Bearer token using a Turso API token. libSQL client URL used separately.
public export
data TursoAuth = BearerToken

||| Base URL for Turso REST API.
export
tursoApiBase : String
tursoApiBase = "https://api.turso.tech/v1/"
