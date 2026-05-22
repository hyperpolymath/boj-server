-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- JiraMcp.SafeComms — Type-safe ABI for the Jira Cloud REST API cartridge.
--
-- Dependent-type state machine governing Jira connection lifecycle.
-- All transitions proven valid at compile time. Zero unsafe escape hatches.

module JiraMcp.SafeComms

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection lifecycle states for Jira API interactions.
||| Models the full lifecycle: Basic auth (email + Atlassian API token),
||| connected operation against https://{instance}.atlassian.net/rest/api/3/,
||| rate limiting, and error recovery.
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
  ||| Authenticate with Basic auth (email + Atlassian API token).
  Authenticate   : ValidTransition Unauthenticated Authenticated
  ||| Hit a Jira rate limit (request budget exhausted).
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
jira_mcp_can_transition : Int -> Int -> Int
jira_mcp_can_transition from to =
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
-- Jira action vocabulary
-- ---------------------------------------------------------------------------

||| All actions supported by the jira-mcp cartridge.
||| Each maps to a Jira Cloud REST API v3 endpoint under
||| https://{instance}.atlassian.net/rest/api/3/.
||| Auth uses Basic auth with email + Atlassian API token (NOT app password).
public export
data JiraAction
  = SearchIssues       -- GET /search (JQL)
  | GetIssue           -- GET /issue/{issueIdOrKey}
  | CreateIssue        -- POST /issue
  | UpdateIssue        -- PUT /issue/{issueIdOrKey}
  | DeleteIssue        -- DELETE /issue/{issueIdOrKey}
  | AddComment         -- POST /issue/{issueIdOrKey}/comment
  | ListProjects       -- GET /project
  | GetProject         -- GET /project/{projectIdOrKey}
  | ListBoards         -- GET /board (Agile API)
  | GetBoard           -- GET /board/{boardId} (Agile API)
  | ListSprints        -- GET /board/{boardId}/sprint (Agile API)
  | GetSprint          -- GET /sprint/{sprintId} (Agile API)
  | TransitionIssue    -- POST /issue/{issueIdOrKey}/transitions
  | AssignIssue        -- PUT /issue/{issueIdOrKey}/assignee
  | ListFields         -- GET /field
  | GetUser            -- GET /user?accountId={accountId}

||| Encode a JiraAction as a C integer for FFI.
export
jiraActionToInt : JiraAction -> Int
jiraActionToInt SearchIssues    = 0
jiraActionToInt GetIssue        = 1
jiraActionToInt CreateIssue     = 2
jiraActionToInt UpdateIssue     = 3
jiraActionToInt DeleteIssue     = 4
jiraActionToInt AddComment      = 5
jiraActionToInt ListProjects    = 6
jiraActionToInt GetProject      = 7
jiraActionToInt ListBoards      = 8
jiraActionToInt GetBoard        = 9
jiraActionToInt ListSprints     = 10
jiraActionToInt GetSprint       = 11
jiraActionToInt TransitionIssue = 12
jiraActionToInt AssignIssue     = 13
jiraActionToInt ListFields      = 14
jiraActionToInt GetUser         = 15

||| Decode a C integer back to a JiraAction.
export
intToJiraAction : Int -> Maybe JiraAction
intToJiraAction 0  = Just SearchIssues
intToJiraAction 1  = Just GetIssue
intToJiraAction 2  = Just CreateIssue
intToJiraAction 3  = Just UpdateIssue
intToJiraAction 4  = Just DeleteIssue
intToJiraAction 5  = Just AddComment
intToJiraAction 6  = Just ListProjects
intToJiraAction 7  = Just GetProject
intToJiraAction 8  = Just ListBoards
intToJiraAction 9  = Just GetBoard
intToJiraAction 10 = Just ListSprints
intToJiraAction 11 = Just GetSprint
intToJiraAction 12 = Just TransitionIssue
intToJiraAction 13 = Just AssignIssue
intToJiraAction 14 = Just ListFields
intToJiraAction 15 = Just GetUser
intToJiraAction _  = Nothing

||| Total action count exposed via C-ABI.
export
jira_mcp_action_count : Int
jira_mcp_action_count = 16

-- ---------------------------------------------------------------------------
-- API classification
-- ---------------------------------------------------------------------------

||| Jira API families: REST v3 for most operations, Agile for boards/sprints.
public export
data ApiFamily = RestV3 | Agile

||| Classify each action by its API family.
export
actionApiFamily : JiraAction -> ApiFamily
actionApiFamily SearchIssues    = RestV3
actionApiFamily GetIssue        = RestV3
actionApiFamily CreateIssue     = RestV3
actionApiFamily UpdateIssue     = RestV3
actionApiFamily DeleteIssue     = RestV3
actionApiFamily AddComment      = RestV3
actionApiFamily ListProjects    = RestV3
actionApiFamily GetProject      = RestV3
actionApiFamily ListBoards      = Agile
actionApiFamily GetBoard        = Agile
actionApiFamily ListSprints     = Agile
actionApiFamily GetSprint       = Agile
actionApiFamily TransitionIssue = RestV3
actionApiFamily AssignIssue     = RestV3
actionApiFamily ListFields      = RestV3
actionApiFamily GetUser         = RestV3

||| C-ABI export: check if an action requires an authenticated state.
||| All Jira actions require authentication.
export
jira_mcp_action_requires_auth : Int -> Int
jira_mcp_action_requires_auth actionId =
  case intToJiraAction actionId of
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
