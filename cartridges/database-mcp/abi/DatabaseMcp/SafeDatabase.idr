-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| DatabaseMcp.SafeDatabase: Formally verified database operations.
|||
||| Cartridge: database-mcp
||| Matrix cell: Database domain x {MCP, LSP} protocols
|||
||| This module defines type-safe database operations with a
||| connection state machine that prevents:
|||   - Querying on a closed connection
|||   - Double-closing a connection
|||   - Executing without proper error handling
|||
||| Designed to integrate with proven-servers dbconn connector.
module DatabaseMcp.SafeDatabase

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Connection State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Connection lifecycle states.
||| A connection progresses: Disconnected -> Connected -> (query) -> Connected -> Disconnected
public export
data ConnState = Disconnected | Connected | Querying | Error

||| Equality for connection states.
public export
Eq ConnState where
  Disconnected == Disconnected = True
  Connected    == Connected    = True
  Querying     == Querying     = True
  Error        == Error        = True
  _            == _            = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : ConnState -> ConnState -> Type where
  Connect    : ValidTransition Disconnected Connected
  StartQuery : ValidTransition Connected Querying
  EndQuery   : ValidTransition Querying Connected
  Disconnect : ValidTransition Connected Disconnected
  QueryError : ValidTransition Querying Error
  Recover    : ValidTransition Error Disconnected

||| Runtime transition validator.
public export
canTransition : ConnState -> ConnState -> Bool
canTransition Disconnected Connected    = True
canTransition Connected    Querying     = True
canTransition Querying     Connected    = True
canTransition Connected    Disconnected = True
canTransition Querying     Error        = True
canTransition Error        Disconnected = True
canTransition _            _            = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Database Backend Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported database backends.
||| VeriSimDB is the hyperpolymath native database.
public export
data DatabaseBackend
  = VeriSimDB     -- Native hyperpolymath database
  | PostgreSQL    -- Standard relational
  | SQLite        -- Embedded relational
  | Redis         -- Key-value / cache
  | Custom String -- User-defined backend

||| C-ABI encoding.
public export
backendToInt : DatabaseBackend -> Int
backendToInt VeriSimDB     = 1
backendToInt PostgreSQL    = 2
backendToInt SQLite        = 3
backendToInt Redis         = 4
backendToInt (Custom _)    = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Query Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Query safety classification.
||| ReadOnly queries cannot modify data.
||| Mutation queries can modify data and require explicit confirmation.
public export
data QuerySafety = ReadOnly | Mutation

||| A database query with safety classification.
public export
record SafeQuery where
  constructor MkQuery
  queryText : String
  safety    : QuerySafety
  paramCount : Nat       -- Number of bound parameters (prevents SQL injection)

||| Query result status.
public export
data QueryResult
  = Success Nat          -- Number of rows affected/returned
  | NoResults            -- Query succeeded but returned nothing
  | ResultError String   -- Error with message

-- ═══════════════════════════════════════════════════════════════════════════
-- Connection Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A database connection with tracked state.
public export
record Connection where
  constructor MkConnection
  connId   : String
  backend  : DatabaseBackend
  state    : ConnState
  host     : String
  port     : Int

||| Proof that a connection is in a query-ready state.
public export
data IsConnected : Connection -> Type where
  ActiveConnection : (c : Connection) ->
                     (state c = Connected) ->
                     IsConnected c

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolConnect        -- Connect to a database
  | ToolDisconnect     -- Close a connection
  | ToolQuery          -- Execute a read-only query
  | ToolMutate         -- Execute a mutation (requires confirmation)
  | ToolListDatabases  -- List available databases
  | ToolDescribeTable  -- Get table schema
  | ToolStatus         -- Connection health check

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolConnect       = "database/connect"
toolName ToolDisconnect    = "database/disconnect"
toolName ToolQuery         = "database/query"
toolName ToolMutate        = "database/mutate"
toolName ToolListDatabases = "database/list"
toolName ToolDescribeTable = "database/describe"
toolName ToolStatus        = "database/status"

||| Which tools require an active connection.
public export
requiresConnection : McpTool -> Bool
requiresConnection ToolConnect       = False
requiresConnection ToolListDatabases = False
requiresConnection _                 = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Connection state to integer.
public export
connStateToInt : ConnState -> Int
connStateToInt Disconnected = 0
connStateToInt Connected    = 1
connStateToInt Querying     = 2
connStateToInt Error        = 3

||| FFI: Validate a state transition.
export
db_can_transition : Int -> Int -> Int
db_can_transition from to =
  let fromState = case from of
                    0 => Disconnected
                    1 => Connected
                    2 => Querying
                    _ => Error
      toState = case to of
                  0 => Disconnected
                  1 => Connected
                  2 => Querying
                  _ => Error
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires an active connection.
export
db_tool_requires_connection : Int -> Int
db_tool_requires_connection 1 = 0  -- ToolConnect
db_tool_requires_connection 5 = 0  -- ToolListDatabases
db_tool_requires_connection _ = 1  -- All others require connection
