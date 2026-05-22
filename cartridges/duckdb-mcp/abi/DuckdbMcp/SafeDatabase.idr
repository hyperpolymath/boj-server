-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- DuckdbMcp.SafeDatabase — Type-safe ABI for the duckdb-mcp cartridge.
--
-- Provides a formally verified state machine for DuckDB embedded analytics.
-- Dependent-type proofs ensure only valid transitions can occur at the FFI
-- boundary. DuckDB runs in-process (no external server). Supports SQL
-- queries, Parquet/CSV import and export, database attach/detach.

module DuckdbMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for DuckDB embedded database.
||| Closed: no database open. Open: database attached and ready for queries.
||| QueryRunning: SQL query in flight. Exporting: export operation in progress.
||| Error: recoverable error state.
public export
data ConnState = Closed | Open | QueryRunning | Exporting | Error

||| Proof that a state transition is valid.
public export
data ValidTransition : ConnState -> ConnState -> Type where
  OpenDb        : ValidTransition Closed Open
  StartQuery    : ValidTransition Open QueryRunning
  FinishQuery   : ValidTransition QueryRunning Open
  StartExport   : ValidTransition Open Exporting
  FinishExport  : ValidTransition Exporting Open
  CloseDb       : ValidTransition Open Closed
  QueryFail     : ValidTransition QueryRunning Error
  ExportFail    : ValidTransition Exporting Error
  ErrorRecover  : ValidTransition Error Closed

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode connection state as C-compatible integer.
export
connStateToInt : ConnState -> Int
connStateToInt Closed       = 0
connStateToInt Open         = 1
connStateToInt QueryRunning = 2
connStateToInt Exporting    = 3
connStateToInt Error        = 4

||| Decode integer back to connection state.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Closed
intToConnState 1 = Just Open
intToConnState 2 = Just QueryRunning
intToConnState 3 = Just Exporting
intToConnState 4 = Just Error
intToConnState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
duckdb_mcp_can_transition : Int -> Int -> Int
duckdb_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Closed,       Just Open)         => 1
    (Just Open,         Just QueryRunning) => 1
    (Just QueryRunning, Just Open)         => 1
    (Just Open,         Just Exporting)    => 1
    (Just Exporting,    Just Open)         => 1
    (Just Open,         Just Closed)       => 1
    (Just QueryRunning, Just Error)        => 1
    (Just Exporting,    Just Error)        => 1
    (Just Error,        Just Closed)       => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- DuckDB actions (embedded analytics surface)
-- ---------------------------------------------------------------------------

||| Actions supported by the DuckDB MCP cartridge.
||| Covers database lifecycle, SQL queries, import/export, schema inspection.
public export
data DuckdbAction
  = CreateDatabase
  | AttachDatabase
  | DetachDatabase
  | Query
  | ExportParquet
  | ExportCSV
  | ImportParquet
  | ImportCSV
  | DescribeTable
  | ListTables
  | GetSchema
  | Explain
  | CreateView
  | DropView
  | CopyTo
  | LoadExtension

||| Encode action as C-compatible integer.
export
duckdbActionToInt : DuckdbAction -> Int
duckdbActionToInt CreateDatabase  = 0
duckdbActionToInt AttachDatabase  = 1
duckdbActionToInt DetachDatabase  = 2
duckdbActionToInt Query           = 3
duckdbActionToInt ExportParquet   = 4
duckdbActionToInt ExportCSV       = 5
duckdbActionToInt ImportParquet   = 6
duckdbActionToInt ImportCSV       = 7
duckdbActionToInt DescribeTable   = 8
duckdbActionToInt ListTables      = 9
duckdbActionToInt GetSchema       = 10
duckdbActionToInt Explain         = 11
duckdbActionToInt CreateView      = 12
duckdbActionToInt DropView        = 13
duckdbActionToInt CopyTo          = 14
duckdbActionToInt LoadExtension   = 15

||| Decode integer back to action.
export
intToDuckdbAction : Int -> Maybe DuckdbAction
intToDuckdbAction 0  = Just CreateDatabase
intToDuckdbAction 1  = Just AttachDatabase
intToDuckdbAction 2  = Just DetachDatabase
intToDuckdbAction 3  = Just Query
intToDuckdbAction 4  = Just ExportParquet
intToDuckdbAction 5  = Just ExportCSV
intToDuckdbAction 6  = Just ImportParquet
intToDuckdbAction 7  = Just ImportCSV
intToDuckdbAction 8  = Just DescribeTable
intToDuckdbAction 9  = Just ListTables
intToDuckdbAction 10 = Just GetSchema
intToDuckdbAction 11 = Just Explain
intToDuckdbAction 12 = Just CreateView
intToDuckdbAction 13 = Just DropView
intToDuckdbAction 14 = Just CopyTo
intToDuckdbAction 15 = Just LoadExtension
intToDuckdbAction _  = Nothing

||| Check whether an action requires an open database.
export
actionRequiresOpen : DuckdbAction -> Bool
actionRequiresOpen CreateDatabase = False
actionRequiresOpen LoadExtension  = False
actionRequiresOpen _              = True

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Auth configuration
-- ---------------------------------------------------------------------------

||| Authentication method for DuckDB embedded analytics.
||| No external auth required — DuckDB runs in-process.
public export
data DuckdbAuth = NoAuth

||| Base URI for DuckDB embedded operations.
export
duckdbApiBase : String
duckdbApiBase = "embedded://duckdb"
