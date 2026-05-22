-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- PrometheusMcp.SafeRegistry — Type-safe ABI for prometheus-mcp cartridge.
--
-- Dependent-type state machine governing Prometheus HTTP API v1 access.
-- Encodes optional Bearer token auth, instant/range PromQL queries,
-- target discovery, alert listing, label browsing, metadata retrieval,
-- and series listing as compile-time invariants.
-- API: https://prometheus.io/docs/prometheus/latest/querying/api/
-- No unsafe escape hatches.

module PrometheusMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Prometheus MCP operations.
||| Unauthenticated: no API token; public read access available.
||| Authenticated:   Prometheus API token active.
||| RateLimited:     query rate limit hit; must wait.
||| Error:           unrecoverable error (network failure, bad query).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Prometheus supports both authenticated and unauthenticated access.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate     : ValidTransition Unauthenticated Authenticated
  Deauthenticate   : ValidTransition Authenticated Unauthenticated
  Throttle         : ValidTransition Authenticated RateLimited
  ThrottleAnon     : ValidTransition Unauthenticated RateLimited
  Unthrottle       : ValidTransition RateLimited Authenticated
  UnthrottleAnon   : ValidTransition RateLimited Unauthenticated
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
prometheus_mcp_can_transition : Int -> Int -> Int
prometheus_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just Unauthenticated, Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just RateLimited,     Just Unauthenticated) => 1
    (Just Authenticated,   Just Error)           => 1
    (Just Unauthenticated, Just Error)           => 1
    (Just Error,           Just Authenticated)   => 1
    (Just Error,           Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Prometheus actions
-- ---------------------------------------------------------------------------

||| Actions available through the Prometheus MCP cartridge.
||| Grouped: Queries, Targets, Alerts, Labels, Metadata, Series.
public export
data PrometheusAction
  = InstantQuery
  | RangeQuery
  | ListTargets
  | ListAlerts
  | ListLabels
  | LabelValues
  | GetMetadata
  | ListSeries

||| Whether an action requires Authenticated state.
||| Prometheus allows unauthenticated read access by default.
export
actionRequiresAuth : PrometheusAction -> Bool
actionRequiresAuth _ = False

||| Whether an action is a write/mutating operation.
||| All Prometheus MCP actions are read-only queries.
export
actionIsMutating : PrometheusAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : PrometheusAction -> Int
actionToInt InstantQuery = 0
actionToInt RangeQuery   = 1
actionToInt ListTargets  = 2
actionToInt ListAlerts   = 3
actionToInt ListLabels   = 4
actionToInt LabelValues  = 5
actionToInt GetMetadata  = 6
actionToInt ListSeries   = 7

||| Decode integer to Prometheus action.
export
intToAction : Int -> Maybe PrometheusAction
intToAction 0 = Just InstantQuery
intToAction 1 = Just RangeQuery
intToAction 2 = Just ListTargets
intToAction 3 = Just ListAlerts
intToAction 4 = Just ListLabels
intToAction 5 = Just LabelValues
intToAction 6 = Just GetMetadata
intToAction 7 = Just ListSeries
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolInstantQuery
  | ToolRangeQuery
  | ToolListTargets
  | ToolListAlerts
  | ToolListLabels
  | ToolLabelValues
  | ToolGetMetadata
  | ToolListSeries

||| Check if a tool requires an authenticated session.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = False

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 8

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 8
