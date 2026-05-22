-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- RenderMcp.SafeCloud -- Type-safe ABI for render-mcp cartridge (Render REST API).
--
-- State machine with dependent-type proofs ensuring only valid transitions
-- can occur at the FFI boundary. Zero unsafe escape hatches.
-- Auth: Bearer token (API key), REST API (https://api.render.com/v1/).
-- Rate limit: 100 req/min.

module RenderMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication / session state machine
-- ---------------------------------------------------------------------------

||| Authentication and session state for Render REST API operations.
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate   : ValidTransition Unauthenticated Authenticated
  BeginRateLimit : ValidTransition Authenticated RateLimited
  EndRateLimit   : ValidTransition RateLimited Authenticated
  AuthError      : ValidTransition Unauthenticated Error
  OpError        : ValidTransition Authenticated Error
  RateError      : ValidTransition RateLimited Error
  RecoverAuth    : ValidTransition Error Unauthenticated
  Deauthenticate : ValidTransition Authenticated Unauthenticated

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
render_mcp_can_transition : Int -> Int -> Int
render_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just Unauthenticated, Just Error)           => 1
    (Just Authenticated,   Just Error)           => 1
    (Just RateLimited,     Just Error)           => 1
    (Just Error,           Just Unauthenticated) => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    _                                            => 0

-- ---------------------------------------------------------------------------
-- Render API actions
-- ---------------------------------------------------------------------------

||| Actions available on the Render REST API v1.
public export
data RenderAction
  = ListServices
  | GetService
  | CreateService
  | DeleteService
  | ListDeploys
  | TriggerDeploy
  | GetDeploy
  | ListEnvGroups
  | GetEnvGroup
  | ListCustomDomains
  | AddCustomDomain
  | ListJobs
  | CreateJob
  | SuspendService
  | ResumeService
  | GetBandwidth

||| Encode action as C-compatible integer for FFI.
export
renderActionToInt : RenderAction -> Int
renderActionToInt ListServices     = 0
renderActionToInt GetService       = 1
renderActionToInt CreateService    = 2
renderActionToInt DeleteService    = 3
renderActionToInt ListDeploys      = 4
renderActionToInt TriggerDeploy    = 5
renderActionToInt GetDeploy        = 6
renderActionToInt ListEnvGroups    = 7
renderActionToInt GetEnvGroup      = 8
renderActionToInt ListCustomDomains = 9
renderActionToInt AddCustomDomain  = 10
renderActionToInt ListJobs         = 11
renderActionToInt CreateJob        = 12
renderActionToInt SuspendService   = 13
renderActionToInt ResumeService    = 14
renderActionToInt GetBandwidth     = 15

||| Decode integer back to action.
export
intToRenderAction : Int -> Maybe RenderAction
intToRenderAction 0  = Just ListServices
intToRenderAction 1  = Just GetService
intToRenderAction 2  = Just CreateService
intToRenderAction 3  = Just DeleteService
intToRenderAction 4  = Just ListDeploys
intToRenderAction 5  = Just TriggerDeploy
intToRenderAction 6  = Just GetDeploy
intToRenderAction 7  = Just ListEnvGroups
intToRenderAction 8  = Just GetEnvGroup
intToRenderAction 9  = Just ListCustomDomains
intToRenderAction 10 = Just AddCustomDomain
intToRenderAction 11 = Just ListJobs
intToRenderAction 12 = Just CreateJob
intToRenderAction 13 = Just SuspendService
intToRenderAction 14 = Just ResumeService
intToRenderAction 15 = Just GetBandwidth
intToRenderAction _  = Nothing

||| Whether an action requires Authenticated state.
||| All Render actions require authentication.
export
actionRequiresAuth : RenderAction -> Bool
actionRequiresAuth _ = True

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

-- ---------------------------------------------------------------------------
-- Rate limit metadata
-- ---------------------------------------------------------------------------

||| Render API rate limit: 100 requests per minute.
export
rateLimitPerMinute : Nat
rateLimitPerMinute = 100

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol.
public export
data McpTool
  = ToolAuthenticate
  | ToolDeauthenticate
  | ToolStatus
  | ToolInvoke
  | ToolList

||| Check if a tool requires an authenticated session.
export
toolRequiresAuth : McpTool -> Bool
toolRequiresAuth ToolAuthenticate   = False
toolRequiresAuth ToolDeauthenticate = True
toolRequiresAuth ToolStatus         = False
toolRequiresAuth ToolInvoke         = True
toolRequiresAuth ToolList           = False

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 5
