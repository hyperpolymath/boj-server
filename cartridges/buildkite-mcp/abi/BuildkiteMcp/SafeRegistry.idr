-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- BuildkiteMcp.SafeRegistry — Type-safe ABI for buildkite-mcp cartridge.
--
-- Dependent-type state machine governing Buildkite REST API v2 access.
-- Encodes Bearer token auth, pipeline listing, build management,
-- job inspection, artifact retrieval, agent listing, build triggering,
-- log retrieval, and cancellation as compile-time invariants.
-- API: https://buildkite.com/docs/apis/rest-api
-- No unsafe escape hatches.

module BuildkiteMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

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
buildkite_mcp_can_transition : Int -> Int -> Int
buildkite_mcp_can_transition from to =
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
-- Buildkite actions
-- ---------------------------------------------------------------------------

public export
data BuildkiteAction
  = ListPipelines
  | GetPipeline
  | ListBuilds
  | GetBuild
  | CreateBuild
  | CancelBuild
  | ListJobs
  | GetJobLog
  | ListArtifacts
  | ListAgents

export
actionRequiresAuth : BuildkiteAction -> Bool
actionRequiresAuth _ = True

export
actionIsMutating : BuildkiteAction -> Bool
actionIsMutating CreateBuild = True
actionIsMutating CancelBuild = True
actionIsMutating _           = False

export
actionToInt : BuildkiteAction -> Int
actionToInt ListPipelines = 0
actionToInt GetPipeline   = 1
actionToInt ListBuilds    = 2
actionToInt GetBuild      = 3
actionToInt CreateBuild   = 4
actionToInt CancelBuild   = 5
actionToInt ListJobs      = 6
actionToInt GetJobLog     = 7
actionToInt ListArtifacts = 8
actionToInt ListAgents    = 9

export
intToAction : Int -> Maybe BuildkiteAction
intToAction 0 = Just ListPipelines
intToAction 1 = Just GetPipeline
intToAction 2 = Just ListBuilds
intToAction 3 = Just GetBuild
intToAction 4 = Just CreateBuild
intToAction 5 = Just CancelBuild
intToAction 6 = Just ListJobs
intToAction 7 = Just GetJobLog
intToAction 8 = Just ListArtifacts
intToAction 9 = Just ListAgents
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

public export
data McpTool
  = ToolListPipelines
  | ToolGetPipeline
  | ToolListBuilds
  | ToolGetBuild
  | ToolCreateBuild
  | ToolCancelBuild
  | ToolListJobs
  | ToolGetJobLog
  | ToolListArtifacts
  | ToolListAgents

export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = True

export
toolCount : Nat
toolCount = 10

export
actionCount : Nat
actionCount = 10
