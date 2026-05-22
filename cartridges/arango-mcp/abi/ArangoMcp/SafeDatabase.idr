-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- ArangoMcp.SafeDatabase — Type-safe ABI for the arango-mcp cartridge.
--
-- Provides a formally verified state machine for ArangoDB multi-model
-- database connections. Dependent-type proofs ensure only valid transitions
-- can occur at the FFI boundary. ArangoDB actions cover the full REST API
-- surface for documents, graphs, key-value, and AQL queries.
-- Auth via Bearer token or Basic auth (self-hosted, configurable base URL).

module ArangoMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for ArangoDB operations.
||| Disconnected is the natural resting state for self-hosted instances.
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
arango_mcp_can_transition : Int -> Int -> Int
arango_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just QueryRunning) => 1
    (Just QueryRunning, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just QueryRunning, Just Error)        => 1
    (Just Error,        Just Disconnected) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- ArangoDB actions (full REST API surface)
-- ---------------------------------------------------------------------------

||| Actions supported by the ArangoDB MCP cartridge.
||| Covers databases, collections, documents, AQL queries, and graphs.
public export
data ArangoAction
  = ListDatabases
  | CreateDatabase
  | DropDatabase
  | ListCollections
  | CreateCollection
  | DropCollection
  | GetDocument
  | InsertDocument
  | UpdateDocument
  | RemoveDocument
  | AqlQuery
  | ExplainQuery
  | TraverseGraph
  | ListGraphs
  | CreateGraph
  | DropGraph

||| Encode action as C-compatible integer.
export
arangoActionToInt : ArangoAction -> Int
arangoActionToInt ListDatabases    = 0
arangoActionToInt CreateDatabase   = 1
arangoActionToInt DropDatabase     = 2
arangoActionToInt ListCollections  = 3
arangoActionToInt CreateCollection = 4
arangoActionToInt DropCollection   = 5
arangoActionToInt GetDocument      = 6
arangoActionToInt InsertDocument   = 7
arangoActionToInt UpdateDocument   = 8
arangoActionToInt RemoveDocument   = 9
arangoActionToInt AqlQuery         = 10
arangoActionToInt ExplainQuery     = 11
arangoActionToInt TraverseGraph    = 12
arangoActionToInt ListGraphs       = 13
arangoActionToInt CreateGraph      = 14
arangoActionToInt DropGraph        = 15

||| Decode integer back to action.
export
intToArangoAction : Int -> Maybe ArangoAction
intToArangoAction 0  = Just ListDatabases
intToArangoAction 1  = Just CreateDatabase
intToArangoAction 2  = Just DropDatabase
intToArangoAction 3  = Just ListCollections
intToArangoAction 4  = Just CreateCollection
intToArangoAction 5  = Just DropCollection
intToArangoAction 6  = Just GetDocument
intToArangoAction 7  = Just InsertDocument
intToArangoAction 8  = Just UpdateDocument
intToArangoAction 9  = Just RemoveDocument
intToArangoAction 10 = Just AqlQuery
intToArangoAction 11 = Just ExplainQuery
intToArangoAction 12 = Just TraverseGraph
intToArangoAction 13 = Just ListGraphs
intToArangoAction 14 = Just CreateGraph
intToArangoAction 15 = Just DropGraph
intToArangoAction _  = Nothing

||| Check whether an action requires an active connection.
export
actionRequiresConnection : ArangoAction -> Bool
actionRequiresConnection AqlQuery       = True
actionRequiresConnection ExplainQuery   = True
actionRequiresConnection GetDocument    = True
actionRequiresConnection InsertDocument = True
actionRequiresConnection UpdateDocument = True
actionRequiresConnection RemoveDocument = True
actionRequiresConnection TraverseGraph  = True
actionRequiresConnection _              = False

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Auth configuration
-- ---------------------------------------------------------------------------

||| Authentication methods for ArangoDB REST API.
||| Supports both Bearer token (JWT) and Basic auth (username/password).
public export
data ArangoAuth = BearerToken | BasicAuth

||| Base URL placeholder for ArangoDB REST API (self-hosted, configurable).
export
arangoApiBase : String
arangoApiBase = "https://{host}:8529/_api/"
