-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- DigitaloceanMcp.SafeCloud — Type-safe ABI for digitalocean-mcp cartridge.
--
-- Formally verified state machine for DigitalOcean API interactions.
-- Bearer token authentication, REST API (https://api.digitalocean.com/v2/).
-- Rate limit: 5000 requests/hour.

module DigitaloceanMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Authentication/session state for DigitalOcean API operations.
||| Unauthenticated: No bearer token configured.
||| Authenticated:   Valid personal access token, ready for API calls.
||| RateLimited:     Hit 5000 req/hour limit, must wait for reset.
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
digitalocean_mcp_can_transition : Int -> Int -> Int
digitalocean_mcp_can_transition from to =
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
-- DigitalOcean API actions
-- ---------------------------------------------------------------------------

||| All supported DigitalOcean REST API actions.
||| Each maps to one or more endpoints under https://api.digitalocean.com/v2/.
public export
data DigitaloceanAction
  = ListDroplets
  | GetDroplet
  | CreateDroplet
  | DeleteDroplet
  | PowerOn
  | PowerOff
  | Reboot
  | ListVolumes
  | CreateVolume
  | ListDomains
  | CreateDomain
  | ListSSHKeys
  | ListSnapshots
  | CreateSnapshot
  | ListDatabases
  | GetAccount

||| Check whether an action requires Authenticated state.
||| All DigitalOcean API calls require a valid bearer token.
export
actionRequiresAuth : DigitaloceanAction -> Bool
actionRequiresAuth ListDroplets   = True
actionRequiresAuth GetDroplet     = True
actionRequiresAuth CreateDroplet  = True
actionRequiresAuth DeleteDroplet  = True
actionRequiresAuth PowerOn        = True
actionRequiresAuth PowerOff       = True
actionRequiresAuth Reboot         = True
actionRequiresAuth ListVolumes    = True
actionRequiresAuth CreateVolume   = True
actionRequiresAuth ListDomains    = True
actionRequiresAuth CreateDomain   = True
actionRequiresAuth ListSSHKeys    = True
actionRequiresAuth ListSnapshots  = True
actionRequiresAuth CreateSnapshot = True
actionRequiresAuth ListDatabases  = True
actionRequiresAuth GetAccount     = True

||| Check whether an action is destructive (mutates remote state).
export
actionIsDestructive : DigitaloceanAction -> Bool
actionIsDestructive CreateDroplet  = True
actionIsDestructive DeleteDroplet  = True
actionIsDestructive PowerOn        = True
actionIsDestructive PowerOff       = True
actionIsDestructive Reboot         = True
actionIsDestructive CreateVolume   = True
actionIsDestructive CreateDomain   = True
actionIsDestructive CreateSnapshot = True
actionIsDestructive _              = False

||| Encode action as C-compatible integer for FFI boundary.
export
actionToInt : DigitaloceanAction -> Int
actionToInt ListDroplets   = 0
actionToInt GetDroplet     = 1
actionToInt CreateDroplet  = 2
actionToInt DeleteDroplet  = 3
actionToInt PowerOn        = 4
actionToInt PowerOff       = 5
actionToInt Reboot         = 6
actionToInt ListVolumes    = 7
actionToInt CreateVolume   = 8
actionToInt ListDomains    = 9
actionToInt CreateDomain   = 10
actionToInt ListSSHKeys    = 11
actionToInt ListSnapshots  = 12
actionToInt CreateSnapshot = 13
actionToInt ListDatabases  = 14
actionToInt GetAccount     = 15

||| Decode integer back to action. Returns Nothing for invalid values.
export
intToAction : Int -> Maybe DigitaloceanAction
intToAction 0  = Just ListDroplets
intToAction 1  = Just GetDroplet
intToAction 2  = Just CreateDroplet
intToAction 3  = Just DeleteDroplet
intToAction 4  = Just PowerOn
intToAction 5  = Just PowerOff
intToAction 6  = Just Reboot
intToAction 7  = Just ListVolumes
intToAction 8  = Just CreateVolume
intToAction 9  = Just ListDomains
intToAction 10 = Just CreateDomain
intToAction 11 = Just ListSSHKeys
intToAction 12 = Just ListSnapshots
intToAction 13 = Just CreateSnapshot
intToAction 14 = Just ListDatabases
intToAction 15 = Just GetAccount
intToAction _  = Nothing

||| Total number of supported actions.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Rate limiting
-- ---------------------------------------------------------------------------

||| DigitalOcean rate limit: 5000 requests per hour.
export
rateLimitPerHour : Nat
rateLimitPerHour = 5000

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolAuthenticate
  | ToolListDroplets
  | ToolGetDroplet
  | ToolCreateDroplet
  | ToolDeleteDroplet
  | ToolPowerAction
  | ToolListVolumes
  | ToolCreateVolume
  | ToolListDomains
  | ToolCreateDomain
  | ToolListSSHKeys
  | ToolListSnapshots
  | ToolCreateSnapshot
  | ToolListDatabases
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
toolCount = 16
