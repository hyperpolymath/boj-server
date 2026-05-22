-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- GrafanaMcp.SafeRegistry — Type-safe ABI for grafana-mcp cartridge.
--
-- Dependent-type state machine governing Grafana HTTP API access.
-- Encodes Bearer token auth, dashboard CRUD, datasource queries,
-- alert rule listing, annotation creation, folder browsing, and
-- health checks as compile-time invariants.
-- API: Grafana HTTP API (/api/*)
-- No unsafe escape hatches.

module GrafanaMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Grafana MCP operations.
||| Unauthenticated: no API token; no operations available.
||| Authenticated:   Grafana API token active, full access.
||| RateLimited:     API rate limit hit; must wait.
||| Error:           unrecoverable error (invalid token, network failure).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Grafana requires authentication for all operations.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate     : ValidTransition Unauthenticated Authenticated
  Deauthenticate   : ValidTransition Authenticated Unauthenticated
  Throttle         : ValidTransition Authenticated RateLimited
  Unthrottle       : ValidTransition RateLimited Authenticated
  AuthError        : ValidTransition Authenticated Error
  AnonError        : ValidTransition Unauthenticated Error
  RecoverToAuth    : ValidTransition Error Authenticated
  RecoverToAnon    : ValidTransition Error Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer for FFI boundary.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Unauthenticated = 0
sessionStateToInt Authenticated   = 1
sessionStateToInt RateLimited     = 2
sessionStateToInt Error           = 3

||| Decode integer back to session state. Returns Nothing for out-of-range.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Unauthenticated
intToSessionState 1 = Just Authenticated
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
export
grafana_mcp_can_transition : Int -> Int -> Int
grafana_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Authenticated,   Just Error)           => 1
    (Just Unauthenticated, Just Error)           => 1
    (Just Error,           Just Authenticated)   => 1
    (Just Error,           Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Grafana actions
-- ---------------------------------------------------------------------------

||| Actions available through the Grafana MCP cartridge.
||| Grouped: Search, Dashboard CRUD, Queries, Alerts, Annotations,
||| Datasources, Folders, Health.
public export
data GrafanaAction
  = SearchDashboards
  | GetDashboard
  | CreateDashboard
  | DeleteDashboard
  | QueryDatasource
  | ListAlerts
  | CreateAnnotation
  | ListDatasources
  | ListFolders
  | Health

||| Whether an action requires Authenticated state.
||| All Grafana API operations require authentication.
export
actionRequiresAuth : GrafanaAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : GrafanaAction -> Bool
actionIsMutating CreateDashboard  = True
actionIsMutating DeleteDashboard  = True
actionIsMutating CreateAnnotation = True
actionIsMutating _                = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : GrafanaAction -> Int
actionToInt SearchDashboards = 0
actionToInt GetDashboard     = 1
actionToInt CreateDashboard  = 2
actionToInt DeleteDashboard  = 3
actionToInt QueryDatasource  = 4
actionToInt ListAlerts       = 5
actionToInt CreateAnnotation = 6
actionToInt ListDatasources  = 7
actionToInt ListFolders      = 8
actionToInt Health           = 9

||| Decode integer to Grafana action.
export
intToAction : Int -> Maybe GrafanaAction
intToAction 0  = Just SearchDashboards
intToAction 1  = Just GetDashboard
intToAction 2  = Just CreateDashboard
intToAction 3  = Just DeleteDashboard
intToAction 4  = Just QueryDatasource
intToAction 5  = Just ListAlerts
intToAction 6  = Just CreateAnnotation
intToAction 7  = Just ListDatasources
intToAction 8  = Just ListFolders
intToAction 9  = Just Health
intToAction _  = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolSearchDashboards
  | ToolGetDashboard
  | ToolCreateDashboard
  | ToolDeleteDashboard
  | ToolQueryDatasource
  | ToolListAlerts
  | ToolCreateAnnotation
  | ToolListDatasources
  | ToolListFolders
  | ToolHealth

||| Check if a tool requires an authenticated session.
||| All Grafana operations require authentication.
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
