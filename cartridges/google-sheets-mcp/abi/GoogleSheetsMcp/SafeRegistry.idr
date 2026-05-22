-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- GoogleSheetsMcp.SafeRegistry — Type-safe ABI for google-sheets-mcp cartridge.
--
-- Dependent-type state machine governing Google Sheets API v4 access.
-- Encodes mandatory OAuth2 auth, spreadsheet retrieval, cell range reading,
-- sheet listing, named range access, cell writing, row appending, sheet
-- creation, batch reading, conditional format listing, and pivot table
-- access as compile-time invariants.
-- REST API: https://sheets.googleapis.com/v4
-- No unsafe escape hatches.

module GoogleSheetsMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Google Sheets MCP operations.
||| Disconnected:  no OAuth2 token configured.
||| Connected:     authenticated and ready for API calls.
||| RateLimited:   rate limit hit; must wait before retrying.
||| Error:         unrecoverable error (expired token, permission denied).
public export
data SessionState
  = Disconnected
  | Connected
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Google Sheets requires OAuth2 auth — no anonymous access.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Connect        : ValidTransition Disconnected Connected
  Disconnect     : ValidTransition Connected Disconnected
  Throttle       : ValidTransition Connected RateLimited
  Unthrottle     : ValidTransition RateLimited Connected
  ConnectError   : ValidTransition Connected Error
  DisconnError   : ValidTransition Disconnected Error
  RecoverConnect : ValidTransition Error Connected
  RecoverDisconn : ValidTransition Error Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer for FFI boundary.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Disconnected = 0
sessionStateToInt Connected    = 1
sessionStateToInt RateLimited  = 2
sessionStateToInt Error        = 3

||| Decode integer back to session state. Returns Nothing for out-of-range.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Disconnected
intToSessionState 1 = Just Connected
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
export
google_sheets_mcp_can_transition : Int -> Int -> Int
google_sheets_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just Connected,    Just RateLimited)  => 1
    (Just RateLimited,  Just Connected)    => 1
    (Just Connected,    Just Error)        => 1
    (Just Disconnected, Just Error)        => 1
    (Just Error,        Just Connected)    => 1
    (Just Error,        Just Disconnected) => 1
    _                                     => 0

-- ---------------------------------------------------------------------------
-- Google Sheets actions
-- ---------------------------------------------------------------------------

||| Actions available through the Google Sheets MCP cartridge.
public export
data GoogleSheetsAction
  = GetSpreadsheet
  | ReadRange
  | ListSheets
  | GetNamedRanges
  | WriteRange
  | AppendRows
  | CreateSheet
  | BatchRead
  | GetConditionalFormats
  | GetPivotTables

||| Whether an action requires Connected state.
export
actionRequiresAuth : GoogleSheetsAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : GoogleSheetsAction -> Bool
actionIsMutating WriteRange   = True
actionIsMutating AppendRows   = True
actionIsMutating CreateSheet  = True
actionIsMutating _            = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : GoogleSheetsAction -> Int
actionToInt GetSpreadsheet       = 0
actionToInt ReadRange            = 1
actionToInt ListSheets           = 2
actionToInt GetNamedRanges       = 3
actionToInt WriteRange           = 4
actionToInt AppendRows           = 5
actionToInt CreateSheet          = 6
actionToInt BatchRead            = 7
actionToInt GetConditionalFormats = 8
actionToInt GetPivotTables       = 9

||| Decode integer to Google Sheets action.
export
intToAction : Int -> Maybe GoogleSheetsAction
intToAction 0 = Just GetSpreadsheet
intToAction 1 = Just ReadRange
intToAction 2 = Just ListSheets
intToAction 3 = Just GetNamedRanges
intToAction 4 = Just WriteRange
intToAction 5 = Just AppendRows
intToAction 6 = Just CreateSheet
intToAction 7 = Just BatchRead
intToAction 8 = Just GetConditionalFormats
intToAction 9 = Just GetPivotTables
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolGetSpreadsheet
  | ToolReadRange
  | ToolListSheets
  | ToolGetNamedRanges
  | ToolWriteRange
  | ToolAppendRows
  | ToolCreateSheet
  | ToolBatchRead
  | ToolGetConditionalFormats
  | ToolGetPivotTables

||| Check if a tool requires a connected session.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = True

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 10

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 10
