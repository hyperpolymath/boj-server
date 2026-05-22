-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- TodoistMcp.SafeRegistry — Type-safe ABI for todoist-mcp cartridge.
--
-- Dependent-type state machine governing Todoist REST API v2 access.
-- Encodes mandatory Bearer token auth, task listing, task creation,
-- task completion, project browsing, label management, comment retrieval,
-- section browsing, and completed task history as compile-time invariants.
-- REST API: https://api.todoist.com/rest/v2
-- No unsafe escape hatches.

module TodoistMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Todoist MCP operations.
||| Disconnected:  no API token configured.
||| Connected:     authenticated and ready for API calls.
||| RateLimited:   rate limit hit; must wait before retrying.
||| Error:         unrecoverable error (invalid token, network failure).
public export
data SessionState
  = Disconnected
  | Connected
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Todoist requires API token auth — no anonymous access.
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
todoist_mcp_can_transition : Int -> Int -> Int
todoist_mcp_can_transition from to =
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
-- Todoist actions
-- ---------------------------------------------------------------------------

||| Actions available through the Todoist MCP cartridge.
||| Grouped: GetTasks, GetTask, CreateTask, CompleteTask,
||| ListProjects, GetProject, ListLabels, GetComments,
||| ListSections, GetCompletedTasks.
public export
data TodoistAction
  = GetTasks
  | GetTask
  | CreateTask
  | CompleteTask
  | ListProjects
  | GetProject
  | ListLabels
  | GetComments
  | ListSections
  | GetCompletedTasks

||| Whether an action requires Connected state.
||| All Todoist operations require an active authenticated session.
export
actionRequiresAuth : TodoistAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
||| CreateTask and CompleteTask are mutating; all others are read-only.
export
actionIsMutating : TodoistAction -> Bool
actionIsMutating CreateTask   = True
actionIsMutating CompleteTask = True
actionIsMutating _            = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : TodoistAction -> Int
actionToInt GetTasks          = 0
actionToInt GetTask           = 1
actionToInt CreateTask        = 2
actionToInt CompleteTask      = 3
actionToInt ListProjects      = 4
actionToInt GetProject        = 5
actionToInt ListLabels        = 6
actionToInt GetComments       = 7
actionToInt ListSections      = 8
actionToInt GetCompletedTasks = 9

||| Decode integer to Todoist action.
export
intToAction : Int -> Maybe TodoistAction
intToAction 0 = Just GetTasks
intToAction 1 = Just GetTask
intToAction 2 = Just CreateTask
intToAction 3 = Just CompleteTask
intToAction 4 = Just ListProjects
intToAction 5 = Just GetProject
intToAction 6 = Just ListLabels
intToAction 7 = Just GetComments
intToAction 8 = Just ListSections
intToAction 9 = Just GetCompletedTasks
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolGetTasks
  | ToolGetTask
  | ToolCreateTask
  | ToolCompleteTask
  | ToolListProjects
  | ToolGetProject
  | ToolListLabels
  | ToolGetComments
  | ToolListSections
  | ToolGetCompletedTasks

||| Check if a tool requires a connected session.
||| All Todoist tools require an active authenticated connection.
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
