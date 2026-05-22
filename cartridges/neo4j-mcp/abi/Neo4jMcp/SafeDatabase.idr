-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Neo4jMcp.SafeDatabase — Type-safe ABI for the neo4j-mcp cartridge.
--
-- Provides a formally verified state machine for Neo4j graph database
-- connections. Dependent-type proofs ensure only valid transitions can occur
-- at the FFI boundary. Neo4j actions cover the HTTP REST API and Bolt protocol
-- surface (https://{host}:7474/). Auth via basic auth (username:password) or
-- bearer token. Supports Cypher query language with EXPLAIN/PROFILE variants.

module Neo4jMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for Neo4j graph database operations.
||| Disconnected is the resting state; Connected after authentication;
||| QueryRunning while a Cypher statement is executing.
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
neo4j_mcp_can_transition : Int -> Int -> Int
neo4j_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just QueryRunning) => 1
    (Just QueryRunning, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just QueryRunning, Just Error)        => 1
    (Just Error,        Just Disconnected) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- Neo4j actions (full API surface)
-- ---------------------------------------------------------------------------

||| Actions supported by the Neo4j MCP cartridge.
||| Covers databases, Cypher queries (execute/explain/profile), nodes,
||| relationships, labels, relationship types, and property keys.
public export
data Neo4jAction
  = ListDatabases
  | CreateDatabase
  | DropDatabase
  | CypherQuery
  | ExplainQuery
  | ProfileQuery
  | CreateNode
  | GetNode
  | UpdateNode
  | DeleteNode
  | CreateRelationship
  | GetRelationship
  | DeleteRelationship
  | ListLabels
  | ListRelationshipTypes
  | ListPropertyKeys

||| Encode action as C-compatible integer.
export
neo4jActionToInt : Neo4jAction -> Int
neo4jActionToInt ListDatabases         = 0
neo4jActionToInt CreateDatabase        = 1
neo4jActionToInt DropDatabase          = 2
neo4jActionToInt CypherQuery           = 3
neo4jActionToInt ExplainQuery          = 4
neo4jActionToInt ProfileQuery          = 5
neo4jActionToInt CreateNode            = 6
neo4jActionToInt GetNode               = 7
neo4jActionToInt UpdateNode            = 8
neo4jActionToInt DeleteNode            = 9
neo4jActionToInt CreateRelationship    = 10
neo4jActionToInt GetRelationship       = 11
neo4jActionToInt DeleteRelationship    = 12
neo4jActionToInt ListLabels            = 13
neo4jActionToInt ListRelationshipTypes = 14
neo4jActionToInt ListPropertyKeys      = 15

||| Decode integer back to action.
export
intToNeo4jAction : Int -> Maybe Neo4jAction
intToNeo4jAction 0  = Just ListDatabases
intToNeo4jAction 1  = Just CreateDatabase
intToNeo4jAction 2  = Just DropDatabase
intToNeo4jAction 3  = Just CypherQuery
intToNeo4jAction 4  = Just ExplainQuery
intToNeo4jAction 5  = Just ProfileQuery
intToNeo4jAction 6  = Just CreateNode
intToNeo4jAction 7  = Just GetNode
intToNeo4jAction 8  = Just UpdateNode
intToNeo4jAction 9  = Just DeleteNode
intToNeo4jAction 10 = Just CreateRelationship
intToNeo4jAction 11 = Just GetRelationship
intToNeo4jAction 12 = Just DeleteRelationship
intToNeo4jAction 13 = Just ListLabels
intToNeo4jAction 14 = Just ListRelationshipTypes
intToNeo4jAction 15 = Just ListPropertyKeys
intToNeo4jAction _  = Nothing

||| Check whether an action requires an active connection.
export
actionRequiresConnection : Neo4jAction -> Bool
actionRequiresConnection CypherQuery           = True
actionRequiresConnection ExplainQuery          = True
actionRequiresConnection ProfileQuery          = True
actionRequiresConnection CreateNode            = True
actionRequiresConnection GetNode               = True
actionRequiresConnection UpdateNode            = True
actionRequiresConnection DeleteNode            = True
actionRequiresConnection CreateRelationship    = True
actionRequiresConnection GetRelationship       = True
actionRequiresConnection DeleteRelationship    = True
actionRequiresConnection ListLabels            = True
actionRequiresConnection ListRelationshipTypes = True
actionRequiresConnection ListPropertyKeys      = True
actionRequiresConnection _                     = False

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Auth configuration
-- ---------------------------------------------------------------------------

||| Authentication method for Neo4j.
||| Basic auth (username:password) for self-hosted, or Bearer token for Aura.
public export
data Neo4jAuth = BasicAuth | BearerToken

||| Base URL template for Neo4j HTTP API.
||| Replace {host} with actual hostname (self-hosted or Aura cloud).
export
neo4jApiBase : String
neo4jApiBase = "https://{host}:7474/"
