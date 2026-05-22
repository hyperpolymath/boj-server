-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- GithubApiMcp.SafeGit — Type-safe ABI for GitHub REST & GraphQL API cartridge.
--
-- Replaces the standalone `npx @modelcontextprotocol/server-github` MCP server.
-- State machine with dependent-type proofs ensuring only valid transitions
-- can occur at the FFI boundary. Zero unsafe escape hatches.

module GithubApiMcp.SafeGit

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Authentication and rate-limit state for GitHub API operations.
|||
||| Unauthenticated : No token set, cannot call API
||| Authenticated   : Valid Bearer token, API calls permitted
||| RateLimited     : GitHub X-RateLimit-Remaining hit zero; must wait
||| Error           : Unrecoverable API/network error; requires reset
public export
data AuthState = Unauthenticated | Authenticated | RateLimited | Error

||| Proof that a state transition is valid.
|||
||| Authenticate  : Unauthenticated -> Authenticated  (token provided)
||| Throttle      : Authenticated   -> RateLimited    (rate limit hit)
||| Resume        : RateLimited     -> Authenticated  (cooldown elapsed)
||| Fault         : Authenticated   -> Error          (API/network failure)
||| ResetError    : Error           -> Unauthenticated (clear error state)
||| Logout        : Authenticated   -> Unauthenticated (explicit logout)
public export
data ValidTransition : AuthState -> AuthState -> Type where
  Authenticate : ValidTransition Unauthenticated Authenticated
  Throttle     : ValidTransition Authenticated   RateLimited
  Resume       : ValidTransition RateLimited     Authenticated
  Fault        : ValidTransition Authenticated   Error
  ResetError   : ValidTransition Error           Unauthenticated
  Logout       : ValidTransition Authenticated   Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding for AuthState
-- ---------------------------------------------------------------------------

||| Encode AuthState as C-compatible integer.
|||
||| Unauthenticated = 0, Authenticated = 1, RateLimited = 2, Error = 3
export
authStateToInt : AuthState -> Int
authStateToInt Unauthenticated = 0
authStateToInt Authenticated   = 1
authStateToInt RateLimited     = 2
authStateToInt Error           = 3

||| Decode integer back to AuthState (returns Nothing for out-of-range values).
export
intToAuthState : Int -> Maybe AuthState
intToAuthState 0 = Just Unauthenticated
intToAuthState 1 = Just Authenticated
intToAuthState 2 = Just RateLimited
intToAuthState 3 = Just Error
intToAuthState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
github_api_mcp_can_transition : Int -> Int -> Int
github_api_mcp_can_transition from to =
  case (intToAuthState from, intToAuthState to) of
    (Just Unauthenticated, Just Authenticated)   => 1  -- Authenticate
    (Just Authenticated,   Just RateLimited)     => 1  -- Throttle
    (Just RateLimited,     Just Authenticated)   => 1  -- Resume
    (Just Authenticated,   Just Error)           => 1  -- Fault
    (Just Error,           Just Unauthenticated) => 1  -- ResetError
    (Just Authenticated,   Just Unauthenticated) => 1  -- Logout
    _                                            => 0

-- ---------------------------------------------------------------------------
-- GitHub action types
-- ---------------------------------------------------------------------------

||| Enumeration of all GitHub API operations this cartridge supports.
|||
||| Covers: repos, issues, PRs, branches, actions, releases, search, code review.
public export
data GitHubAction
  = ListRepos
  | GetRepo
  | CreateIssue
  | ListIssues
  | GetIssue
  | CommentIssue
  | CreatePR
  | ListPRs
  | GetPR
  | MergePR
  | ReviewPR
  | ListBranches
  | CreateBranch
  | SearchCode
  | SearchIssues
  | ListActions
  | GetRelease
  | CreateRelease
  | GetFileContents
  | PushFiles

||| Encode GitHubAction as C-compatible integer for FFI boundary.
export
actionToInt : GitHubAction -> Int
actionToInt ListRepos       = 0
actionToInt GetRepo         = 1
actionToInt CreateIssue     = 2
actionToInt ListIssues      = 3
actionToInt GetIssue        = 4
actionToInt CommentIssue    = 5
actionToInt CreatePR        = 6
actionToInt ListPRs         = 7
actionToInt GetPR           = 8
actionToInt MergePR         = 9
actionToInt ReviewPR        = 10
actionToInt ListBranches    = 11
actionToInt CreateBranch    = 12
actionToInt SearchCode      = 13
actionToInt SearchIssues    = 14
actionToInt ListActions     = 15
actionToInt GetRelease      = 16
actionToInt CreateRelease   = 17
actionToInt GetFileContents = 18
actionToInt PushFiles       = 19

||| Decode integer to GitHubAction.
export
intToAction : Int -> Maybe GitHubAction
intToAction 0  = Just ListRepos
intToAction 1  = Just GetRepo
intToAction 2  = Just CreateIssue
intToAction 3  = Just ListIssues
intToAction 4  = Just GetIssue
intToAction 5  = Just CommentIssue
intToAction 6  = Just CreatePR
intToAction 7  = Just ListPRs
intToAction 8  = Just GetPR
intToAction 9  = Just MergePR
intToAction 10 = Just ReviewPR
intToAction 11 = Just ListBranches
intToAction 12 = Just CreateBranch
intToAction 13 = Just SearchCode
intToAction 14 = Just SearchIssues
intToAction 15 = Just ListActions
intToAction 16 = Just GetRelease
intToAction 17 = Just CreateRelease
intToAction 18 = Just GetFileContents
intToAction 19 = Just PushFiles
intToAction _  = Nothing

||| Total count of supported GitHub actions.
export
actionCount : Nat
actionCount = 20

-- ---------------------------------------------------------------------------
-- Action requirements: which state is needed?
-- ---------------------------------------------------------------------------

||| Every GitHubAction requires the Authenticated state.
||| (All GitHub API calls need a valid token.)
export
actionRequiresAuth : GitHubAction -> Bool
actionRequiresAuth _ = True

||| Check if a given action performs a mutation (write operation).
export
actionIsMutation : GitHubAction -> Bool
actionIsMutation CreateIssue    = True
actionIsMutation CommentIssue   = True
actionIsMutation CreatePR       = True
actionIsMutation MergePR        = True
actionIsMutation ReviewPR       = True
actionIsMutation CreateBranch   = True
actionIsMutation CreateRelease  = True
actionIsMutation PushFiles      = True
actionIsMutation _              = False

-- ---------------------------------------------------------------------------
-- Rate limit record
-- ---------------------------------------------------------------------------

||| Rate limit information parsed from GitHub API response headers.
|||
||| remaining : Calls left in the current window
||| resetTime : Unix epoch seconds when the window resets
||| limit     : Maximum calls permitted per window
public export
record RateLimit where
  constructor MkRateLimit
  remaining : Nat
  resetTime : Nat
  limit     : Nat

||| Check if rate-limited (zero remaining calls).
export
isRateLimited : RateLimit -> Bool
isRateLimited rl = remaining rl == 0

-- ---------------------------------------------------------------------------
-- C-ABI exports for action validation
-- ---------------------------------------------------------------------------

||| Validate an action code. Returns 1 if valid, 0 if out of range.
export
github_api_mcp_valid_action : Int -> Int
github_api_mcp_valid_action code =
  case intToAction code of
    Just _  => 1
    Nothing => 0

||| Check if an action is a mutation. Returns 1 for mutation, 0 for read-only,
||| -1 for invalid action code.
export
github_api_mcp_is_mutation : Int -> Int
github_api_mcp_is_mutation code =
  case intToAction code of
    Just act => if actionIsMutation act then 1 else 0
    Nothing  => -1

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for the GitHub API cartridge.
public export
data McpTool
  = ToolAuthenticate
  | ToolRequest
  | ToolGraphQL
  | ToolStatus
  | ToolRateLimit
  | ToolListTools

||| Check if a tool requires an authenticated session.
export
toolRequiresAuth : McpTool -> Bool
toolRequiresAuth ToolAuthenticate = False
toolRequiresAuth ToolRequest      = True
toolRequiresAuth ToolGraphQL      = True
toolRequiresAuth ToolStatus       = False
toolRequiresAuth ToolRateLimit    = False
toolRequiresAuth ToolListTools    = False

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 6
