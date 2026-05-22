-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- RailwayMcp.SafeCloud -- Type-safe ABI for railway-mcp cartridge (Railway GraphQL API).
--
-- State machine with dependent-type proofs ensuring only valid transitions
-- can occur at the FFI boundary. Zero unsafe escape hatches.
-- Auth: Bearer token (API token), GraphQL API (https://backboard.railway.app/graphql/v2).

module RailwayMcp.SafeCloud

%default total

-- ---------------------------------------------------------------------------
-- Authentication / session state machine
-- ---------------------------------------------------------------------------

||| Authentication and session state for Railway GraphQL API operations.
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
railway_mcp_can_transition : Int -> Int -> Int
railway_mcp_can_transition from to =
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
-- Railway API actions
-- ---------------------------------------------------------------------------

||| Actions available on the Railway GraphQL API v2.
public export
data RailwayAction
  = ListProjects
  | GetProject
  | CreateProject
  | DeleteProject
  | ListServices
  | GetService
  | ListDeployments
  | GetDeployment
  | Redeploy
  | ListVariables
  | SetVariable
  | DeleteVariable
  | ListDomains
  | AddDomain
  | GetLogs
  | GetMetrics

||| Encode action as C-compatible integer for FFI.
export
railwayActionToInt : RailwayAction -> Int
railwayActionToInt ListProjects    = 0
railwayActionToInt GetProject      = 1
railwayActionToInt CreateProject   = 2
railwayActionToInt DeleteProject   = 3
railwayActionToInt ListServices    = 4
railwayActionToInt GetService      = 5
railwayActionToInt ListDeployments = 6
railwayActionToInt GetDeployment   = 7
railwayActionToInt Redeploy        = 8
railwayActionToInt ListVariables   = 9
railwayActionToInt SetVariable     = 10
railwayActionToInt DeleteVariable  = 11
railwayActionToInt ListDomains     = 12
railwayActionToInt AddDomain       = 13
railwayActionToInt GetLogs         = 14
railwayActionToInt GetMetrics      = 15

||| Decode integer back to action.
export
intToRailwayAction : Int -> Maybe RailwayAction
intToRailwayAction 0  = Just ListProjects
intToRailwayAction 1  = Just GetProject
intToRailwayAction 2  = Just CreateProject
intToRailwayAction 3  = Just DeleteProject
intToRailwayAction 4  = Just ListServices
intToRailwayAction 5  = Just GetService
intToRailwayAction 6  = Just ListDeployments
intToRailwayAction 7  = Just GetDeployment
intToRailwayAction 8  = Just Redeploy
intToRailwayAction 9  = Just ListVariables
intToRailwayAction 10 = Just SetVariable
intToRailwayAction 11 = Just DeleteVariable
intToRailwayAction 12 = Just ListDomains
intToRailwayAction 13 = Just AddDomain
intToRailwayAction 14 = Just GetLogs
intToRailwayAction 15 = Just GetMetrics
intToRailwayAction _  = Nothing

||| Whether an action requires Authenticated state.
||| All Railway actions require authentication (no public endpoints).
export
actionRequiresAuth : RailwayAction -> Bool
actionRequiresAuth _ = True

||| Total number of actions exposed by this cartridge.
export
actionCount : Nat
actionCount = 16

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
