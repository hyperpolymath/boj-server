-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- SentryMcp.SafeRegistry — Type-safe ABI for sentry-mcp cartridge.
--
-- Dependent-type state machine governing Sentry API access.
-- Encodes Bearer token auth, issue listing, event retrieval,
-- project browsing, release management, DSN lookup, teams,
-- tag search, resolution, and performance transactions
-- as compile-time invariants.
-- API: https://docs.sentry.io/api/
-- No unsafe escape hatches.

module SentryMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Sentry MCP operations.
||| Unauthenticated: no API token; no operations available.
||| Authenticated:   Sentry auth token active, full access.
||| RateLimited:     API rate limit hit; must wait.
||| Error:           unrecoverable error (invalid token, network failure).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Sentry requires authentication for all operations.
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

||| Decode integer back to session state.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Unauthenticated
intToSessionState 1 = Just Authenticated
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
export
sentry_mcp_can_transition : Int -> Int -> Int
sentry_mcp_can_transition from to =
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
-- Sentry actions
-- ---------------------------------------------------------------------------

||| Actions available through the Sentry MCP cartridge.
public export
data SentryAction
  = ListIssues
  | GetIssue
  | ListEvents
  | ResolveIssue
  | ListProjects
  | ListReleases
  | GetDsn
  | ListTeams
  | SearchTags
  | ListTransactions

||| Whether an action requires Authenticated state.
||| All Sentry API operations require authentication.
export
actionRequiresAuth : SentryAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : SentryAction -> Bool
actionIsMutating ResolveIssue = True
actionIsMutating _            = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : SentryAction -> Int
actionToInt ListIssues       = 0
actionToInt GetIssue         = 1
actionToInt ListEvents       = 2
actionToInt ResolveIssue     = 3
actionToInt ListProjects     = 4
actionToInt ListReleases     = 5
actionToInt GetDsn           = 6
actionToInt ListTeams        = 7
actionToInt SearchTags       = 8
actionToInt ListTransactions = 9

||| Decode integer to Sentry action.
export
intToAction : Int -> Maybe SentryAction
intToAction 0 = Just ListIssues
intToAction 1 = Just GetIssue
intToAction 2 = Just ListEvents
intToAction 3 = Just ResolveIssue
intToAction 4 = Just ListProjects
intToAction 5 = Just ListReleases
intToAction 6 = Just GetDsn
intToAction 7 = Just ListTeams
intToAction 8 = Just SearchTags
intToAction 9 = Just ListTransactions
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolListIssues
  | ToolGetIssue
  | ToolListEvents
  | ToolResolveIssue
  | ToolListProjects
  | ToolListReleases
  | ToolGetDsn
  | ToolListTeams
  | ToolSearchTags
  | ToolListTransactions

||| Check if a tool requires an authenticated session.
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
