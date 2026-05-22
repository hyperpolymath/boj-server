-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- PostgresqlMcp.SafeDatabase -- Type-safe ABI for postgresql-mcp cartridge.
--
-- Dependently-typed state machine modelling PostgreSQL connection lifecycle.
-- Transitions are proven valid at compile time. Credentials obtained from
-- vault-mcp via connection string (postgres://user:pass@host:5432/db).
-- All queries use parameterised statements to prevent SQL injection.

module PostgresqlMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| PostgreSQL connection lifecycle states.
|||
||| @ Disconnected  No active connection to the database server.
||| @ Connected     Authenticated connection established; ready for queries.
||| @ InTransaction Inside an explicit BEGIN block.
||| @ QueryRunning  A query or statement is currently executing.
||| @ Error         An error has occurred; must disconnect to recover.
public export
data ConnState
  = Disconnected
  | Connected
  | InTransaction
  | QueryRunning
  | Error

||| Proof that a state transition is valid within the PostgreSQL protocol.
|||
||| The transition graph:
|||   Disconnected -> Connected        (connect)
|||   Connected    -> InTransaction    (begin)
|||   InTransaction -> Connected       (commit / rollback)
|||   Connected    -> QueryRunning     (query / execute)
|||   InTransaction -> QueryRunning    (query inside transaction)
|||   QueryRunning -> Connected        (query completes outside tx)
|||   QueryRunning -> InTransaction    (query completes inside tx -- see note)
|||   QueryRunning -> Error            (query fails)
|||   Error        -> Disconnected     (disconnect after error)
|||   Connected    -> Disconnected     (graceful disconnect)
public export
data ValidTransition : ConnState -> ConnState -> Type where
  Connect          : ValidTransition Disconnected Connected
  Disconnect       : ValidTransition Connected Disconnected
  BeginTx          : ValidTransition Connected InTransaction
  CommitTx         : ValidTransition InTransaction Connected
  RollbackTx       : ValidTransition InTransaction Connected
  StartQuery       : ValidTransition Connected QueryRunning
  StartTxQuery     : ValidTransition InTransaction QueryRunning
  QueryDone        : ValidTransition QueryRunning Connected
  TxQueryDone      : ValidTransition QueryRunning InTransaction
  QueryFailed      : ValidTransition QueryRunning Error
  ErrorDisconnect  : ValidTransition Error Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode connection state as C-compatible integer.
export
connStateToInt : ConnState -> Int
connStateToInt Disconnected  = 0
connStateToInt Connected     = 1
connStateToInt InTransaction = 2
connStateToInt QueryRunning  = 3
connStateToInt Error         = 4

||| Decode integer back to connection state.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Disconnected
intToConnState 1 = Just Connected
intToConnState 2 = Just InTransaction
intToConnState 3 = Just QueryRunning
intToConnState 4 = Just Error
intToConnState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
postgresql_mcp_can_transition : Int -> Int -> Int
postgresql_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected,  Just Connected)     => 1
    (Just Connected,     Just Disconnected)  => 1
    (Just Connected,     Just InTransaction) => 1
    (Just InTransaction, Just Connected)     => 1
    (Just Connected,     Just QueryRunning)  => 1
    (Just InTransaction, Just QueryRunning)  => 1
    (Just QueryRunning,  Just Connected)     => 1
    (Just QueryRunning,  Just InTransaction) => 1
    (Just QueryRunning,  Just Error)         => 1
    (Just Error,         Just Disconnected)  => 1
    _                                        => 0

-- ---------------------------------------------------------------------------
-- PostgreSQL actions
-- ---------------------------------------------------------------------------

||| Actions exposed via the postgresql-mcp MCP protocol.
|||
||| All 16 operations supported by this cartridge. Query and Execute use
||| parameterised statements exclusively to prevent SQL injection.
public export
data PostgresqlAction
  = Connect
  | Disconnect
  | Query
  | Execute
  | BeginTransaction
  | CommitTransaction
  | RollbackTransaction
  | ListDatabases
  | ListSchemas
  | ListTables
  | DescribeTable
  | ListIndices
  | Explain
  | CopyTo
  | CopyFrom
  | Notify

||| Encode action as C-compatible integer.
export
actionToInt : PostgresqlAction -> Int
actionToInt Connect              = 0
actionToInt Disconnect           = 1
actionToInt Query                = 2
actionToInt Execute              = 3
actionToInt BeginTransaction     = 4
actionToInt CommitTransaction    = 5
actionToInt RollbackTransaction  = 6
actionToInt ListDatabases        = 7
actionToInt ListSchemas          = 8
actionToInt ListTables           = 9
actionToInt DescribeTable        = 10
actionToInt ListIndices          = 11
actionToInt Explain              = 12
actionToInt CopyTo               = 13
actionToInt CopyFrom             = 14
actionToInt Notify               = 15

||| Decode integer back to action.
export
intToAction : Int -> Maybe PostgresqlAction
intToAction 0  = Just Connect
intToAction 1  = Just Disconnect
intToAction 2  = Just Query
intToAction 3  = Just Execute
intToAction 4  = Just BeginTransaction
intToAction 5  = Just CommitTransaction
intToAction 6  = Just RollbackTransaction
intToAction 7  = Just ListDatabases
intToAction 8  = Just ListSchemas
intToAction 9  = Just ListTables
intToAction 10 = Just DescribeTable
intToAction 11 = Just ListIndices
intToAction 12 = Just Explain
intToAction 13 = Just CopyTo
intToAction 14 = Just CopyFrom
intToAction 15 = Just Notify
intToAction _  = Nothing

||| Check whether an action requires an active connection (Connected or deeper).
export
actionRequiresConnection : PostgresqlAction -> Bool
actionRequiresConnection Connect  = False
actionRequiresConnection _        = True

||| Check whether an action requires an active transaction.
export
actionRequiresTransaction : PostgresqlAction -> Bool
actionRequiresTransaction CommitTransaction   = True
actionRequiresTransaction RollbackTransaction = True
actionRequiresTransaction _                   = False

||| Total number of actions in this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Authentication
-- ---------------------------------------------------------------------------

||| Authentication method for PostgreSQL connections.
||| Credentials are sourced from vault-mcp, never hardcoded.
public export
data AuthMethod
  = ConnectionString
  | VaultRef String

-- ---------------------------------------------------------------------------
-- Result types
-- ---------------------------------------------------------------------------

||| Query result status codes matching libpq PGresult status.
public export
data ResultStatus
  = CommandOk
  | TuplesOk
  | CopyOut
  | CopyIn
  | BadResponse
  | FatalError

||| Encode result status as C-compatible integer.
export
resultStatusToInt : ResultStatus -> Int
resultStatusToInt CommandOk   = 0
resultStatusToInt TuplesOk    = 1
resultStatusToInt CopyOut     = 2
resultStatusToInt CopyIn      = 3
resultStatusToInt BadResponse = 4
resultStatusToInt FatalError  = 5

||| Decode integer back to result status.
export
intToResultStatus : Int -> Maybe ResultStatus
intToResultStatus 0 = Just CommandOk
intToResultStatus 1 = Just TuplesOk
intToResultStatus 2 = Just CopyOut
intToResultStatus 3 = Just CopyIn
intToResultStatus 4 = Just BadResponse
intToResultStatus 5 = Just FatalError
intToResultStatus _ = Nothing
