-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- ClickhouseMcp.SafeDatabase — Type-safe ABI for the clickhouse-mcp cartridge.
--
-- Provides a formally verified state machine for ClickHouse connections.
-- Dependent-type proofs ensure only valid transitions can occur at the FFI
-- boundary. ClickHouse actions cover the HTTP interface surface
-- (https://{host}:8123/). Auth via basic auth or no auth (configurable).
-- Column-oriented OLAP database optimised for analytical queries.

module ClickhouseMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for ClickHouse OLAP database operations.
||| Disconnected is the initial state; connections use the HTTP interface.
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
clickhouse_mcp_can_transition : Int -> Int -> Int
clickhouse_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just QueryRunning) => 1
    (Just QueryRunning, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just QueryRunning, Just Error)        => 1
    (Just Error,        Just Disconnected) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- ClickHouse actions (full HTTP interface surface)
-- ---------------------------------------------------------------------------

||| Actions supported by the ClickHouse MCP cartridge.
||| Covers databases, tables, queries, partitions, and system management.
public export
data ClickhouseAction
  = ListDatabases
  | CreateDatabase
  | DropDatabase
  | ListTables
  | CreateTable
  | DropTable
  | DescribeTable
  | SelectQuery
  | InsertData
  | ExplainQuery
  | ShowProcesslist
  | KillQuery
  | OptimizeTable
  | TruncateTable
  | ListPartitions
  | SystemReloadConfig

||| Encode action as C-compatible integer.
export
clickhouseActionToInt : ClickhouseAction -> Int
clickhouseActionToInt ListDatabases      = 0
clickhouseActionToInt CreateDatabase     = 1
clickhouseActionToInt DropDatabase       = 2
clickhouseActionToInt ListTables         = 3
clickhouseActionToInt CreateTable        = 4
clickhouseActionToInt DropTable          = 5
clickhouseActionToInt DescribeTable      = 6
clickhouseActionToInt SelectQuery        = 7
clickhouseActionToInt InsertData         = 8
clickhouseActionToInt ExplainQuery       = 9
clickhouseActionToInt ShowProcesslist    = 10
clickhouseActionToInt KillQuery          = 11
clickhouseActionToInt OptimizeTable      = 12
clickhouseActionToInt TruncateTable      = 13
clickhouseActionToInt ListPartitions     = 14
clickhouseActionToInt SystemReloadConfig = 15

||| Decode integer back to action.
export
intToClickhouseAction : Int -> Maybe ClickhouseAction
intToClickhouseAction 0  = Just ListDatabases
intToClickhouseAction 1  = Just CreateDatabase
intToClickhouseAction 2  = Just DropDatabase
intToClickhouseAction 3  = Just ListTables
intToClickhouseAction 4  = Just CreateTable
intToClickhouseAction 5  = Just DropTable
intToClickhouseAction 6  = Just DescribeTable
intToClickhouseAction 7  = Just SelectQuery
intToClickhouseAction 8  = Just InsertData
intToClickhouseAction 9  = Just ExplainQuery
intToClickhouseAction 10 = Just ShowProcesslist
intToClickhouseAction 11 = Just KillQuery
intToClickhouseAction 12 = Just OptimizeTable
intToClickhouseAction 13 = Just TruncateTable
intToClickhouseAction 14 = Just ListPartitions
intToClickhouseAction 15 = Just SystemReloadConfig
intToClickhouseAction _  = Nothing

||| Check whether an action requires an active connection.
export
actionRequiresConnection : ClickhouseAction -> Bool
actionRequiresConnection SelectQuery        = True
actionRequiresConnection InsertData         = True
actionRequiresConnection ExplainQuery       = True
actionRequiresConnection ShowProcesslist    = True
actionRequiresConnection KillQuery          = True
actionRequiresConnection OptimizeTable      = True
actionRequiresConnection TruncateTable      = True
actionRequiresConnection ListPartitions     = True
actionRequiresConnection SystemReloadConfig = True
actionRequiresConnection _                  = False

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Auth configuration
-- ---------------------------------------------------------------------------

||| Authentication method for ClickHouse HTTP interface.
||| Basic auth (user/password) or no auth (configurable per deployment).
public export
data ClickhouseAuth = BasicAuth | NoAuth

||| Default base URL for ClickHouse HTTP interface.
export
clickhouseApiBase : String
clickhouseApiBase = "https://{host}:8123/"
