-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- CircleciMcp.SafeRegistry — Type-safe ABI for circleci-mcp cartridge.
--
-- Dependent-type state machine governing CircleCI API v2 access.
-- Encodes Circle-Token auth, pipeline listing, workflow management,
-- job inspection, artifact retrieval, pipeline triggering, workflow
-- cancellation, and environment variable browsing as compile-time invariants.
-- API: https://circleci.com/docs/api/v2/
-- No unsafe escape hatches.

module CircleciMcp.SafeRegistry

%default total

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
circleci_mcp_can_transition : Int -> Int -> Int
circleci_mcp_can_transition from to =
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

public export
data CircleciAction
  = ListPipelines
  | GetPipeline
  | ListWorkflows
  | GetWorkflow
  | ListJobs
  | ListArtifacts
  | TriggerPipeline
  | CancelWorkflow
  | ListEnvVars

export
actionRequiresAuth : CircleciAction -> Bool
actionRequiresAuth _ = True

export
actionIsMutating : CircleciAction -> Bool
actionIsMutating TriggerPipeline = True
actionIsMutating CancelWorkflow  = True
actionIsMutating _               = False

export
actionToInt : CircleciAction -> Int
actionToInt ListPipelines   = 0
actionToInt GetPipeline     = 1
actionToInt ListWorkflows   = 2
actionToInt GetWorkflow     = 3
actionToInt ListJobs        = 4
actionToInt ListArtifacts   = 5
actionToInt TriggerPipeline = 6
actionToInt CancelWorkflow  = 7
actionToInt ListEnvVars     = 8

export
intToAction : Int -> Maybe CircleciAction
intToAction 0 = Just ListPipelines
intToAction 1 = Just GetPipeline
intToAction 2 = Just ListWorkflows
intToAction 3 = Just GetWorkflow
intToAction 4 = Just ListJobs
intToAction 5 = Just ListArtifacts
intToAction 6 = Just TriggerPipeline
intToAction 7 = Just CancelWorkflow
intToAction 8 = Just ListEnvVars
intToAction _ = Nothing

public export
data McpTool
  = ToolListPipelines
  | ToolGetPipeline
  | ToolListWorkflows
  | ToolGetWorkflow
  | ToolListJobs
  | ToolListArtifacts
  | ToolTriggerPipeline
  | ToolCancelWorkflow
  | ToolListEnvVars

export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = True

export
toolCount : Nat
toolCount = 9

export
actionCount : Nat
actionCount = 9
