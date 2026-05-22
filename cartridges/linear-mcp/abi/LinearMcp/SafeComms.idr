-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- LinearMcp.SafeComms — Type-safe ABI for the Linear GraphQL API cartridge.
--
-- Dependent-type state machine governing Linear connection lifecycle.
-- All transitions proven valid at compile time. Zero unsafe escape hatches.

module LinearMcp.SafeComms

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection lifecycle states for Linear API interactions.
||| Models the full lifecycle: authentication via Bearer token,
||| connected operation against the GraphQL endpoint, rate limiting
||| (Linear enforces request-based limits), and error recovery.
public export
data ConnState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

-- ---------------------------------------------------------------------------
-- Valid state transitions (proven at the type level)
-- ---------------------------------------------------------------------------

||| Proof witness that a state transition is permitted.
||| Only the transitions enumerated here can ever occur at the FFI boundary.
public export
data ValidTransition : ConnState -> ConnState -> Type where
  ||| Authenticate with a Linear API key (Bearer token).
  Authenticate   : ValidTransition Unauthenticated Authenticated
  ||| Hit a Linear rate limit (complexity or request budget exhausted).
  HitRateLimit   : ValidTransition Authenticated RateLimited
  ||| Rate limit window expired — resume operations.
  RateRecovered  : ValidTransition RateLimited Authenticated
  ||| Operational error while authenticated (network, API fault).
  AuthError      : ValidTransition Authenticated Error
  ||| Rate-limited session encounters an unrecoverable error.
  RateLimitError : ValidTransition RateLimited Error
  ||| Error recovery — return to unauthenticated for re-auth.
  ErrorReset     : ValidTransition Error Unauthenticated
  ||| Graceful disconnect from an authenticated session.
  GracefulClose  : ValidTransition Authenticated Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding for ConnState
-- ---------------------------------------------------------------------------

||| Encode connection state as a C-compatible integer.
||| Mapping: Unauthenticated=0, Authenticated=1, RateLimited=2, Error=3.
export
connStateToInt : ConnState -> Int
connStateToInt Unauthenticated = 0
connStateToInt Authenticated   = 1
connStateToInt RateLimited     = 2
connStateToInt Error           = 3

||| Decode a C integer back to a connection state.
||| Returns Nothing for out-of-range values.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Unauthenticated
intToConnState 1 = Just Authenticated
intToConnState 2 = Just RateLimited
intToConnState 3 = Just Error
intToConnState _ = Nothing

||| C-ABI export: check whether a state transition is valid.
||| Returns 1 for valid, 0 for invalid. Used by the Zig FFI layer.
export
linear_mcp_can_transition : Int -> Int -> Int
linear_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Authenticated,   Just Error)           => 1
    (Just RateLimited,     Just Error)           => 1
    (Just Error,           Just Unauthenticated) => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Linear action vocabulary
-- ---------------------------------------------------------------------------

||| All actions supported by the linear-mcp cartridge.
||| Each maps to a Linear GraphQL query or mutation via
||| the endpoint https://api.linear.app/graphql.
public export
data LinearAction
  = ListIssues           -- Query: issues
  | GetIssue             -- Query: issue(id)
  | CreateIssue          -- Mutation: issueCreate
  | UpdateIssue          -- Mutation: issueUpdate
  | DeleteIssue          -- Mutation: issueDelete
  | ListProjects         -- Query: projects
  | GetProject           -- Query: project(id)
  | ListTeams            -- Query: teams
  | ListCycles           -- Query: cycles
  | CreateComment        -- Mutation: commentCreate
  | SearchIssues         -- Query: issueSearch
  | ListLabels           -- Query: issueLabels
  | AssignIssue          -- Mutation: issueUpdate (assigneeId)
  | SetPriority          -- Mutation: issueUpdate (priority)
  | MoveToProject        -- Mutation: issueUpdate (projectId)
  | ListWorkflowStates   -- Query: workflowStates

||| Encode a LinearAction as a C integer for FFI.
export
linearActionToInt : LinearAction -> Int
linearActionToInt ListIssues         = 0
linearActionToInt GetIssue           = 1
linearActionToInt CreateIssue        = 2
linearActionToInt UpdateIssue        = 3
linearActionToInt DeleteIssue        = 4
linearActionToInt ListProjects       = 5
linearActionToInt GetProject         = 6
linearActionToInt ListTeams          = 7
linearActionToInt ListCycles         = 8
linearActionToInt CreateComment      = 9
linearActionToInt SearchIssues       = 10
linearActionToInt ListLabels         = 11
linearActionToInt AssignIssue        = 12
linearActionToInt SetPriority        = 13
linearActionToInt MoveToProject      = 14
linearActionToInt ListWorkflowStates = 15

||| Decode a C integer back to a LinearAction.
export
intToLinearAction : Int -> Maybe LinearAction
intToLinearAction 0  = Just ListIssues
intToLinearAction 1  = Just GetIssue
intToLinearAction 2  = Just CreateIssue
intToLinearAction 3  = Just UpdateIssue
intToLinearAction 4  = Just DeleteIssue
intToLinearAction 5  = Just ListProjects
intToLinearAction 6  = Just GetProject
intToLinearAction 7  = Just ListTeams
intToLinearAction 8  = Just ListCycles
intToLinearAction 9  = Just CreateComment
intToLinearAction 10 = Just SearchIssues
intToLinearAction 11 = Just ListLabels
intToLinearAction 12 = Just AssignIssue
intToLinearAction 13 = Just SetPriority
intToLinearAction 14 = Just MoveToProject
intToLinearAction 15 = Just ListWorkflowStates
intToLinearAction _  = Nothing

||| Total action count exposed via C-ABI.
export
linear_mcp_action_count : Int
linear_mcp_action_count = 16

-- ---------------------------------------------------------------------------
-- Action classification
-- ---------------------------------------------------------------------------

||| Whether an action is a mutation (write) or query (read).
||| Used to determine if additional confirmation is needed.
public export
data ActionKind = Query | Mutation

||| Classify each action as a query or mutation.
export
actionKind : LinearAction -> ActionKind
actionKind ListIssues         = Query
actionKind GetIssue           = Query
actionKind CreateIssue        = Mutation
actionKind UpdateIssue        = Mutation
actionKind DeleteIssue        = Mutation
actionKind ListProjects       = Query
actionKind GetProject         = Query
actionKind ListTeams          = Query
actionKind ListCycles         = Query
actionKind CreateComment      = Mutation
actionKind SearchIssues       = Query
actionKind ListLabels         = Query
actionKind AssignIssue        = Mutation
actionKind SetPriority        = Mutation
actionKind MoveToProject      = Mutation
actionKind ListWorkflowStates = Query

||| C-ABI export: check if an action requires an authenticated state.
||| All Linear actions require authentication.
export
linear_mcp_action_requires_auth : Int -> Int
linear_mcp_action_requires_auth actionId =
  case intToLinearAction actionId of
    Just _  => 1  -- all actions require Authenticated state
    Nothing => 0  -- unknown action

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via the MCP protocol by this cartridge.
public export
data McpTool
  = ToolConnect
  | ToolDisconnect
  | ToolStatus
  | ToolInvoke
  | ToolList

||| Check if a tool requires an authenticated session.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession ToolConnect    = False
toolRequiresSession ToolDisconnect = True
toolRequiresSession ToolStatus     = False
toolRequiresSession ToolInvoke     = True
toolRequiresSession ToolList       = False

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 5
