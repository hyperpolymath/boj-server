-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- GithubActionsMcp.SafeRegistry — Type-safe ABI for github-actions-mcp cartridge.
--
-- Dependent-type state machine governing GitHub Actions API access.
-- Encodes Bearer token auth, workflow listing, run management, job inspection,
-- artifact listing, log retrieval, dispatch, re-run, cancellation, secret listing,
-- runner listing, and cache management as compile-time invariants.
-- API: https://docs.github.com/en/rest/actions
-- No unsafe escape hatches.

module GithubActionsMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for GitHub Actions MCP operations.
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| GitHub Actions requires authentication for all operations.
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

export
sessionStateToInt : SessionState -> Int
sessionStateToInt Unauthenticated = 0
sessionStateToInt Authenticated   = 1
sessionStateToInt RateLimited     = 2
sessionStateToInt Error           = 3

export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Unauthenticated
intToSessionState 1 = Just Authenticated
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

export
gha_mcp_can_transition : Int -> Int -> Int
gha_mcp_can_transition from to =
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
-- GitHub Actions actions
-- ---------------------------------------------------------------------------

||| Actions available through the GitHub Actions MCP cartridge.
public export
data GhaAction
  = ListWorkflows
  | ListRuns
  | GetRun
  | ListJobs
  | GetLogs
  | ListArtifacts
  | DispatchWorkflow
  | RerunWorkflow
  | CancelRun
  | ListSecrets
  | ListRunners
  | ListCaches

||| Whether an action requires Authenticated state.
export
actionRequiresAuth : GhaAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
export
actionIsMutating : GhaAction -> Bool
actionIsMutating DispatchWorkflow = True
actionIsMutating RerunWorkflow    = True
actionIsMutating CancelRun        = True
actionIsMutating _                = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : GhaAction -> Int
actionToInt ListWorkflows    = 0
actionToInt ListRuns         = 1
actionToInt GetRun           = 2
actionToInt ListJobs         = 3
actionToInt GetLogs          = 4
actionToInt ListArtifacts    = 5
actionToInt DispatchWorkflow = 6
actionToInt RerunWorkflow    = 7
actionToInt CancelRun        = 8
actionToInt ListSecrets      = 9
actionToInt ListRunners      = 10
actionToInt ListCaches       = 11

||| Decode integer to GHA action.
export
intToAction : Int -> Maybe GhaAction
intToAction 0  = Just ListWorkflows
intToAction 1  = Just ListRuns
intToAction 2  = Just GetRun
intToAction 3  = Just ListJobs
intToAction 4  = Just GetLogs
intToAction 5  = Just ListArtifacts
intToAction 6  = Just DispatchWorkflow
intToAction 7  = Just RerunWorkflow
intToAction 8  = Just CancelRun
intToAction 9  = Just ListSecrets
intToAction 10 = Just ListRunners
intToAction 11 = Just ListCaches
intToAction _  = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

public export
data McpTool
  = ToolListWorkflows
  | ToolListRuns
  | ToolGetRun
  | ToolListJobs
  | ToolGetLogs
  | ToolListArtifacts
  | ToolDispatchWorkflow
  | ToolRerunWorkflow
  | ToolCancelRun
  | ToolListSecrets
  | ToolListRunners
  | ToolListCaches

export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = True

export
toolCount : Nat
toolCount = 12

export
actionCount : Nat
actionCount = 12
