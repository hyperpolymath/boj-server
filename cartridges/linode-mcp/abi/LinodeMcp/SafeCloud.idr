-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- LinodeMcp.SafeCloud — Type-safe ABI for linode-mcp cartridge.
--
-- Formally verified state machine for Linode/Akamai API interactions.
-- Bearer token authentication, REST API (https://api.linode.com/v4/).
-- Rate limit: 800 requests per 2 minutes.

module LinodeMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Authentication/session state for Linode API operations.
||| Unauthenticated: No bearer token configured.
||| Authenticated:   Valid personal access token, ready for API calls.
||| RateLimited:     Hit 800 req/2min limit, must wait for reset.
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
linode_mcp_can_transition : Int -> Int -> Int
linode_mcp_can_transition from to =
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
-- Linode API actions
-- ---------------------------------------------------------------------------

||| All supported Linode REST API actions.
||| Each maps to one or more endpoints under https://api.linode.com/v4/.
public export
data LinodeAction
  = ListInstances
  | GetInstance
  | CreateInstance
  | DeleteInstance
  | Boot
  | Shutdown
  | Reboot
  | ListVolumes
  | CreateVolume
  | ListDomains
  | CreateDomain
  | ListNodeBalancers
  | ListStackScripts
  | ListImages
  | ListRegions
  | GetAccount

||| Check whether an action requires Authenticated state.
||| All Linode API calls require a valid bearer token.
export
actionRequiresAuth : LinodeAction -> Bool
actionRequiresAuth ListInstances     = True
actionRequiresAuth GetInstance       = True
actionRequiresAuth CreateInstance    = True
actionRequiresAuth DeleteInstance    = True
actionRequiresAuth Boot              = True
actionRequiresAuth Shutdown          = True
actionRequiresAuth Reboot            = True
actionRequiresAuth ListVolumes       = True
actionRequiresAuth CreateVolume      = True
actionRequiresAuth ListDomains       = True
actionRequiresAuth CreateDomain      = True
actionRequiresAuth ListNodeBalancers = True
actionRequiresAuth ListStackScripts  = True
actionRequiresAuth ListImages        = True
actionRequiresAuth ListRegions       = True
actionRequiresAuth GetAccount        = True

||| Check whether an action is destructive (mutates remote state).
export
actionIsDestructive : LinodeAction -> Bool
actionIsDestructive CreateInstance = True
actionIsDestructive DeleteInstance = True
actionIsDestructive Boot           = True
actionIsDestructive Shutdown       = True
actionIsDestructive Reboot         = True
actionIsDestructive CreateVolume   = True
actionIsDestructive CreateDomain   = True
actionIsDestructive _              = False

||| Encode action as C-compatible integer for FFI boundary.
export
actionToInt : LinodeAction -> Int
actionToInt ListInstances     = 0
actionToInt GetInstance       = 1
actionToInt CreateInstance    = 2
actionToInt DeleteInstance    = 3
actionToInt Boot              = 4
actionToInt Shutdown          = 5
actionToInt Reboot            = 6
actionToInt ListVolumes       = 7
actionToInt CreateVolume      = 8
actionToInt ListDomains       = 9
actionToInt CreateDomain      = 10
actionToInt ListNodeBalancers = 11
actionToInt ListStackScripts  = 12
actionToInt ListImages        = 13
actionToInt ListRegions       = 14
actionToInt GetAccount        = 15

||| Decode integer back to action. Returns Nothing for invalid values.
export
intToAction : Int -> Maybe LinodeAction
intToAction 0  = Just ListInstances
intToAction 1  = Just GetInstance
intToAction 2  = Just CreateInstance
intToAction 3  = Just DeleteInstance
intToAction 4  = Just Boot
intToAction 5  = Just Shutdown
intToAction 6  = Just Reboot
intToAction 7  = Just ListVolumes
intToAction 8  = Just CreateVolume
intToAction 9  = Just ListDomains
intToAction 10 = Just CreateDomain
intToAction 11 = Just ListNodeBalancers
intToAction 12 = Just ListStackScripts
intToAction 13 = Just ListImages
intToAction 14 = Just ListRegions
intToAction 15 = Just GetAccount
intToAction _  = Nothing

||| Total number of supported actions.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Rate limiting
-- ---------------------------------------------------------------------------

||| Linode rate limit: 800 requests per 2 minutes.
export
rateLimitPerWindow : Nat
rateLimitPerWindow = 800

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolAuthenticate
  | ToolListInstances
  | ToolGetInstance
  | ToolCreateInstance
  | ToolDeleteInstance
  | ToolBootAction
  | ToolShutdownAction
  | ToolRebootAction
  | ToolListVolumes
  | ToolCreateVolume
  | ToolListDomains
  | ToolCreateDomain
  | ToolListNodeBalancers
  | ToolListStackScripts
  | ToolListImages
  | ToolGetAccount
  | ToolStatus

||| Check if a tool requires authenticated state.
export
toolRequiresAuth : McpTool -> Bool
toolRequiresAuth ToolAuthenticate = False
toolRequiresAuth ToolStatus       = False
toolRequiresAuth _                = True

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 17
