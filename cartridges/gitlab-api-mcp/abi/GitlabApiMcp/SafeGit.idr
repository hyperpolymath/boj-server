-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- GitlabApiMcp.SafeGit — Type-safe ABI for the gitlab-api-mcp cartridge.
--
-- Dependently-typed state machine ensuring only valid authentication and
-- session transitions can occur at the FFI boundary. Supports both
-- gitlab.com and self-hosted GitLab instances via InstanceConfig.
-- Zero unsafe escape hatches.

module GitlabApiMcp.SafeGit

%default total

-- ---------------------------------------------------------------------------
-- State machine
-- ---------------------------------------------------------------------------

||| Authentication/session state for GitLab API operations.
||| Unauthenticated: no valid token set.
||| Authenticated:   token validated, ready to make API calls.
||| RateLimited:     secondary rate limit hit, must back off before retry.
||| Error:           unrecoverable error (bad token, network failure, etc.).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Mirrors the GitHub cartridge pattern:
|||   Unauth -> Auth      (successful authentication)
|||   Auth   -> RateLimit (rate limit hit)
|||   Rate   -> Auth      (backoff complete, resume)
|||   Auth   -> Error     (request/network failure)
|||   Error  -> Unauth    (reset / re-init)
|||   Auth   -> Unauth    (explicit logout / token revoke)
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate   : ValidTransition Unauthenticated Authenticated
  HitRateLimit   : ValidTransition Authenticated   RateLimited
  ResumeFromRate : ValidTransition RateLimited      Authenticated
  RequestError   : ValidTransition Authenticated    Error
  ResetFromError : ValidTransition Error             Unauthenticated
  Logout         : ValidTransition Authenticated    Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer.
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
||| Returns 1 for valid, 0 for invalid.
export
gitlab_api_mcp_can_transition : Int -> Int -> Int
gitlab_api_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1  -- authenticate
    (Just Authenticated,   Just RateLimited)     => 1  -- rate limit hit
    (Just RateLimited,     Just Authenticated)   => 1  -- resume
    (Just Authenticated,   Just Error)           => 1  -- request error
    (Just Error,           Just Unauthenticated) => 1  -- reset
    (Just Authenticated,   Just Unauthenticated) => 1  -- logout
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Instance configuration
-- ---------------------------------------------------------------------------

||| Configuration for a GitLab instance (gitlab.com or self-hosted).
public export
record InstanceConfig where
  constructor MkInstanceConfig
  ||| Base URL, e.g. "https://gitlab.com" or "https://git.example.org"
  baseUrl    : String
  ||| API version path segment, e.g. "v4"
  apiVersion : String

||| Default configuration targeting gitlab.com REST API v4.
export
defaultInstance : InstanceConfig
defaultInstance = MkInstanceConfig "https://gitlab.com" "v4"

-- ---------------------------------------------------------------------------
-- GitLab action types
-- ---------------------------------------------------------------------------

||| All GitLab REST/GraphQL actions exposed by this cartridge.
public export
data GitLabAction
  = ListProjects
  | GetProject
  | CreateIssue
  | ListIssues
  | GetIssue
  | CommentIssue
  | CreateMR
  | ListMRs
  | GetMR
  | MergeMR
  | ListBranches
  | CreateBranch
  | SearchCode
  | ListPipelines
  | GetPipeline
  | TriggerPipeline
  | ListReleases
  | CreateRelease
  | PushMirror
  | GetFileContents

||| Total count of supported actions.
export
actionCount : Nat
actionCount = 20

||| Encode action as C-compatible integer for FFI dispatch.
export
actionToInt : GitLabAction -> Int
actionToInt ListProjects    = 0
actionToInt GetProject      = 1
actionToInt CreateIssue     = 2
actionToInt ListIssues      = 3
actionToInt GetIssue        = 4
actionToInt CommentIssue    = 5
actionToInt CreateMR        = 6
actionToInt ListMRs         = 7
actionToInt GetMR           = 8
actionToInt MergeMR         = 9
actionToInt ListBranches    = 10
actionToInt CreateBranch    = 11
actionToInt SearchCode      = 12
actionToInt ListPipelines   = 13
actionToInt GetPipeline     = 14
actionToInt TriggerPipeline = 15
actionToInt ListReleases    = 16
actionToInt CreateRelease   = 17
actionToInt PushMirror      = 18
actionToInt GetFileContents = 19

||| Decode integer back to action.
export
intToAction : Int -> Maybe GitLabAction
intToAction 0  = Just ListProjects
intToAction 1  = Just GetProject
intToAction 2  = Just CreateIssue
intToAction 3  = Just ListIssues
intToAction 4  = Just GetIssue
intToAction 5  = Just CommentIssue
intToAction 6  = Just CreateMR
intToAction 7  = Just ListMRs
intToAction 8  = Just GetMR
intToAction 9  = Just MergeMR
intToAction 10 = Just ListBranches
intToAction 11 = Just CreateBranch
intToAction 12 = Just SearchCode
intToAction 13 = Just ListPipelines
intToAction 14 = Just GetPipeline
intToAction 15 = Just TriggerPipeline
intToAction 16 = Just ListReleases
intToAction 17 = Just CreateRelease
intToAction 18 = Just PushMirror
intToAction 19 = Just GetFileContents
intToAction _  = Nothing

||| Check whether an action requires an authenticated session.
||| All GitLab API operations require authentication.
export
actionRequiresAuth : GitLabAction -> Bool
actionRequiresAuth _ = True

-- ---------------------------------------------------------------------------
-- HTTP method mapping
-- ---------------------------------------------------------------------------

||| HTTP method for a given action.
public export
data HttpMethod = GET | POST | PUT | DELETE

||| Determine the HTTP method for each action.
export
actionMethod : GitLabAction -> HttpMethod
actionMethod ListProjects    = GET
actionMethod GetProject      = GET
actionMethod CreateIssue     = POST
actionMethod ListIssues      = GET
actionMethod GetIssue        = GET
actionMethod CommentIssue    = POST
actionMethod CreateMR        = POST
actionMethod ListMRs         = GET
actionMethod GetMR           = GET
actionMethod MergeMR         = PUT
actionMethod ListBranches    = GET
actionMethod CreateBranch    = POST
actionMethod SearchCode      = GET
actionMethod ListPipelines   = GET
actionMethod GetPipeline     = GET
actionMethod TriggerPipeline = POST
actionMethod ListReleases    = GET
actionMethod CreateRelease   = POST
actionMethod PushMirror      = POST
actionMethod GetFileContents = GET

-- ---------------------------------------------------------------------------
-- C-ABI exports for action validation
-- ---------------------------------------------------------------------------

||| Validate an action integer is in range. Returns 1 (valid) or 0 (invalid).
export
gitlab_api_mcp_valid_action : Int -> Int
gitlab_api_mcp_valid_action n =
  case intToAction n of
    Just _  => 1
    Nothing => 0

||| Check if an action requires authentication. Returns 1 (yes) or 0 (no).
export
gitlab_api_mcp_action_requires_auth : Int -> Int
gitlab_api_mcp_action_requires_auth n =
  case intToAction n of
    Just act => if actionRequiresAuth act then 1 else 0
    Nothing  => -1
