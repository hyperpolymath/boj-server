-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- DockerHubMcp.SafeContainer — Type-safe ABI for docker-hub-mcp cartridge.
--
-- Formally verified state machine for Docker Hub API interactions.
-- Two-phase auth: POST /v2/users/login -> JWT bearer token.
-- REST API (https://hub.docker.com/v2/).
-- Pull rate limit: 100 pulls/6h (anonymous), 200 pulls/6h (authenticated).

module DockerHubMcp.SafeContainer

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Authentication/session state for Docker Hub API operations.
||| Unauthenticated: No JWT token acquired.
||| Authenticated:   Valid JWT from /v2/users/login, ready for API calls.
||| RateLimited:     Hit pull rate limit (100 anon / 200 auth per 6h).
||| Error:           API or network error requiring recovery.
public export
data AuthState = Unauthenticated | Authenticated | RateLimited | Error

||| Proof that a state transition is valid.
||| Only well-typed transitions compile — invalid paths are rejected.
public export
data ValidTransition : AuthState -> AuthState -> Type where
  Authenticate   : ValidTransition Unauthenticated Authenticated
  HitRateLimit   : ValidTransition Authenticated RateLimited
  RateLimitReset : ValidTransition RateLimited Authenticated
  AuthError      : ValidTransition Authenticated Error
  RateLimitError : ValidTransition RateLimited Error
  RecoverToAuth  : ValidTransition Error Authenticated
  Logout         : ValidTransition Authenticated Unauthenticated
  ErrorLogout    : ValidTransition Error Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode auth state as C-compatible integer for FFI boundary.
export
authStateToInt : AuthState -> Int
authStateToInt Unauthenticated = 0
authStateToInt Authenticated   = 1
authStateToInt RateLimited     = 2
authStateToInt Error           = 3

||| Decode integer back to auth state. Returns Nothing for invalid values.
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
docker_hub_mcp_can_transition : Int -> Int -> Int
docker_hub_mcp_can_transition from to =
  case (intToAuthState from, intToAuthState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Authenticated,   Just Error)           => 1
    (Just RateLimited,     Just Error)           => 1
    (Just Error,           Just Authenticated)   => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    (Just Error,           Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Docker Hub API actions
-- ---------------------------------------------------------------------------

||| All supported Docker Hub REST API actions.
||| Each maps to one or more endpoints under https://hub.docker.com/v2/.
public export
data DockerHubAction
  = SearchImages
  | GetRepository
  | ListTags
  | GetTag
  | ListNamespaces
  | GetManifest
  | DeleteTag
  | GetRateLimit
  | ListOrgs
  | CreateRepository
  | DeleteRepository
  | GetDockerfile
  | ListStarred
  | StarRepository
  | UnstarRepository
  | GetUser

||| Check whether an action requires Authenticated state.
||| Most Docker Hub API calls require a valid JWT.
export
actionRequiresAuth : DockerHubAction -> Bool
actionRequiresAuth SearchImages     = False
actionRequiresAuth GetRateLimit     = False
actionRequiresAuth GetRepository    = True
actionRequiresAuth ListTags         = True
actionRequiresAuth GetTag           = True
actionRequiresAuth ListNamespaces   = True
actionRequiresAuth GetManifest      = True
actionRequiresAuth DeleteTag        = True
actionRequiresAuth ListOrgs         = True
actionRequiresAuth CreateRepository = True
actionRequiresAuth DeleteRepository = True
actionRequiresAuth GetDockerfile    = True
actionRequiresAuth ListStarred      = True
actionRequiresAuth StarRepository   = True
actionRequiresAuth UnstarRepository = True
actionRequiresAuth GetUser          = True

||| Check whether an action is destructive (mutates remote state).
export
actionIsDestructive : DockerHubAction -> Bool
actionIsDestructive DeleteTag        = True
actionIsDestructive CreateRepository = True
actionIsDestructive DeleteRepository = True
actionIsDestructive StarRepository   = True
actionIsDestructive UnstarRepository = True
actionIsDestructive _                = False

||| Encode action as C-compatible integer for FFI boundary.
export
actionToInt : DockerHubAction -> Int
actionToInt SearchImages     = 0
actionToInt GetRepository    = 1
actionToInt ListTags         = 2
actionToInt GetTag           = 3
actionToInt ListNamespaces   = 4
actionToInt GetManifest      = 5
actionToInt DeleteTag        = 6
actionToInt GetRateLimit     = 7
actionToInt ListOrgs         = 8
actionToInt CreateRepository = 9
actionToInt DeleteRepository = 10
actionToInt GetDockerfile    = 11
actionToInt ListStarred      = 12
actionToInt StarRepository   = 13
actionToInt UnstarRepository = 14
actionToInt GetUser          = 15

||| Decode integer back to action. Returns Nothing for invalid values.
export
intToAction : Int -> Maybe DockerHubAction
intToAction 0  = Just SearchImages
intToAction 1  = Just GetRepository
intToAction 2  = Just ListTags
intToAction 3  = Just GetTag
intToAction 4  = Just ListNamespaces
intToAction 5  = Just GetManifest
intToAction 6  = Just DeleteTag
intToAction 7  = Just GetRateLimit
intToAction 8  = Just ListOrgs
intToAction 9  = Just CreateRepository
intToAction 10 = Just DeleteRepository
intToAction 11 = Just GetDockerfile
intToAction 12 = Just ListStarred
intToAction 13 = Just StarRepository
intToAction 14 = Just UnstarRepository
intToAction 15 = Just GetUser
intToAction _  = Nothing

||| Total number of supported actions.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Rate limiting
-- ---------------------------------------------------------------------------

||| Docker Hub authenticated pull rate limit: 200 pulls per 6 hours.
export
pullRateLimitAuth : Nat
pullRateLimitAuth = 200

||| Docker Hub anonymous pull rate limit: 100 pulls per 6 hours.
export
pullRateLimitAnon : Nat
pullRateLimitAnon = 100

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolAuthenticate
  | ToolSearchImages
  | ToolGetRepository
  | ToolListTags
  | ToolGetTag
  | ToolListNamespaces
  | ToolGetManifest
  | ToolDeleteTag
  | ToolGetRateLimit
  | ToolListOrgs
  | ToolCreateRepository
  | ToolDeleteRepository
  | ToolGetDockerfile
  | ToolListStarred
  | ToolStarRepository
  | ToolGetUser
  | ToolStatus

||| Check if a tool requires authenticated state.
export
toolRequiresAuth : McpTool -> Bool
toolRequiresAuth ToolAuthenticate = False
toolRequiresAuth ToolSearchImages = False
toolRequiresAuth ToolGetRateLimit = False
toolRequiresAuth ToolStatus       = False
toolRequiresAuth _                = True

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 17
