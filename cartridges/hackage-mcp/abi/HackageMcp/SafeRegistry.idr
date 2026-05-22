-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- HackageMcp.SafeRegistry — Type-safe ABI for hackage-mcp cartridge.
--
-- Dependent-type state machine governing Hackage API access.
-- Encodes optional Basic auth, package search, metadata retrieval,
-- version listing, download stats, dependency analysis, reverse deps,
-- maintainer listing, deprecation checks, cabal file retrieval,
-- and user profile lookup as compile-time invariants.
-- REST API: https://hackage.haskell.org
-- No unsafe escape hatches.

module HackageMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Hackage MCP operations.
||| Unauthenticated: no credentials; read-only operations available.
||| Authenticated:   Hackage credentials active, full access.
||| RateLimited:     Hackage rate limit hit (429); must wait.
||| Error:           unrecoverable error (invalid credentials, network failure).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Hackage allows both authenticated and unauthenticated sessions.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Authenticate     : ValidTransition Unauthenticated Authenticated
  Deauthenticate   : ValidTransition Authenticated Unauthenticated
  Throttle         : ValidTransition Authenticated RateLimited
  ThrottleAnon     : ValidTransition Unauthenticated RateLimited
  Unthrottle       : ValidTransition RateLimited Authenticated
  UnthrottleAnon   : ValidTransition RateLimited Unauthenticated
  AuthError        : ValidTransition Authenticated Error
  AnonError        : ValidTransition Unauthenticated Error
  RecoverToAuth    : ValidTransition Error Authenticated
  RecoverToAnon    : ValidTransition Error Unauthenticated

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer for FFI boundary.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Unauthenticated = 0
sessionStateToInt Authenticated   = 1
sessionStateToInt RateLimited     = 2
sessionStateToInt Error           = 3

||| Decode integer back to session state. Returns Nothing for out-of-range.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Unauthenticated
intToSessionState 1 = Just Authenticated
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
export
hackage_mcp_can_transition : Int -> Int -> Int
hackage_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Unauthenticated, Just Authenticated)   => 1
    (Just Authenticated,   Just Unauthenticated) => 1
    (Just Authenticated,   Just RateLimited)     => 1
    (Just Unauthenticated, Just RateLimited)     => 1
    (Just RateLimited,     Just Authenticated)   => 1
    (Just RateLimited,     Just Unauthenticated) => 1
    (Just Authenticated,   Just Error)           => 1
    (Just Unauthenticated, Just Error)           => 1
    (Just Error,           Just Authenticated)   => 1
    (Just Error,           Just Unauthenticated) => 1
    _                                           => 0

-- ---------------------------------------------------------------------------
-- Hackage actions
-- ---------------------------------------------------------------------------

||| Actions available through the Hackage MCP cartridge.
||| Grouped: Search, Metadata, Versions, Downloads, Dependencies,
||| ReverseDeps, Maintainers, Deprecation, CabalFile, ListAll, Users.
public export
data HackageAction
  = SearchPackages
  | GetPackage
  | GetVersion
  | ListVersions
  | GetDownloads
  | GetDependencies
  | GetReverseDependencies
  | GetMaintainers
  | GetDeprecated
  | GetCabalFile
  | ListAllPackages
  | GetUser

||| Whether an action requires Authenticated state.
||| All Hackage read operations work without auth.
export
actionRequiresAuth : HackageAction -> Bool
actionRequiresAuth _ = False

||| Whether an action is a write/mutating operation.
||| All hackage-mcp actions are read-only queries.
export
actionIsMutating : HackageAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : HackageAction -> Int
actionToInt SearchPackages        = 0
actionToInt GetPackage            = 1
actionToInt GetVersion            = 2
actionToInt ListVersions          = 3
actionToInt GetDownloads          = 4
actionToInt GetDependencies       = 5
actionToInt GetReverseDependencies = 6
actionToInt GetMaintainers        = 7
actionToInt GetDeprecated         = 8
actionToInt GetCabalFile          = 9
actionToInt ListAllPackages       = 10
actionToInt GetUser               = 11

||| Decode integer to Hackage action.
export
intToAction : Int -> Maybe HackageAction
intToAction 0  = Just SearchPackages
intToAction 1  = Just GetPackage
intToAction 2  = Just GetVersion
intToAction 3  = Just ListVersions
intToAction 4  = Just GetDownloads
intToAction 5  = Just GetDependencies
intToAction 6  = Just GetReverseDependencies
intToAction 7  = Just GetMaintainers
intToAction 8  = Just GetDeprecated
intToAction 9  = Just GetCabalFile
intToAction 10 = Just ListAllPackages
intToAction 11 = Just GetUser
intToAction _  = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolSearchPackages
  | ToolGetPackage
  | ToolGetVersion
  | ToolListVersions
  | ToolGetDownloads
  | ToolGetDependencies
  | ToolGetReverseDependencies
  | ToolGetMaintainers
  | ToolGetDeprecated
  | ToolGetCabalFile
  | ToolListAllPackages
  | ToolGetUser

||| Check if a tool requires an authenticated session.
||| All Hackage read operations work without auth.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = False

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 12

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 12
