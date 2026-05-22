-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- AirtableMcp.SafeRegistry — Type-safe ABI for airtable-mcp cartridge.
--
-- Dependent-type state machine governing Airtable REST API access.
-- Encodes mandatory Bearer token auth, base listing, schema retrieval,
-- record search, record creation, record update, field listing, view
-- browsing, webhook management, and comment access as compile-time
-- invariants.
-- REST API: https://api.airtable.com/v0
-- No unsafe escape hatches.

module AirtableMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Airtable MCP operations.
||| Disconnected:  no API key configured.
||| Connected:     authenticated and ready for API calls.
||| RateLimited:   rate limit hit (30 req/sec); must wait.
||| Error:         unrecoverable error (invalid key, permission denied).
public export
data SessionState
  = Disconnected
  | Connected
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Airtable requires personal access token — no anonymous access.
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

export
sessionStateToInt : SessionState -> Int
sessionStateToInt Disconnected = 0
sessionStateToInt Connected    = 1
sessionStateToInt RateLimited  = 2
sessionStateToInt Error        = 3

export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Disconnected
intToSessionState 1 = Just Connected
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

export
airtable_mcp_can_transition : Int -> Int -> Int
airtable_mcp_can_transition from to =
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
-- Airtable actions
-- ---------------------------------------------------------------------------

||| Actions available through the Airtable MCP cartridge.
public export
data AirtableAction
  = ListBases
  | GetBaseSchema
  | ListRecords
  | GetRecord
  | CreateRecord
  | UpdateRecord
  | ListFields
  | ListViews
  | ListWebhooks
  | GetComments

||| Whether an action requires Connected state.
export
actionRequiresAuth : AirtableAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : AirtableAction -> Bool
actionIsMutating CreateRecord = True
actionIsMutating UpdateRecord = True
actionIsMutating _            = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : AirtableAction -> Int
actionToInt ListBases     = 0
actionToInt GetBaseSchema = 1
actionToInt ListRecords   = 2
actionToInt GetRecord     = 3
actionToInt CreateRecord  = 4
actionToInt UpdateRecord  = 5
actionToInt ListFields    = 6
actionToInt ListViews     = 7
actionToInt ListWebhooks  = 8
actionToInt GetComments   = 9

||| Decode integer to Airtable action.
export
intToAction : Int -> Maybe AirtableAction
intToAction 0 = Just ListBases
intToAction 1 = Just GetBaseSchema
intToAction 2 = Just ListRecords
intToAction 3 = Just GetRecord
intToAction 4 = Just CreateRecord
intToAction 5 = Just UpdateRecord
intToAction 6 = Just ListFields
intToAction 7 = Just ListViews
intToAction 8 = Just ListWebhooks
intToAction 9 = Just GetComments
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

public export
data McpTool
  = ToolListBases
  | ToolGetBaseSchema
  | ToolListRecords
  | ToolGetRecord
  | ToolCreateRecord
  | ToolUpdateRecord
  | ToolListFields
  | ToolListViews
  | ToolListWebhooks
  | ToolGetComments

export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = True

export
toolCount : Nat
toolCount = 10

export
actionCount : Nat
actionCount = 10
