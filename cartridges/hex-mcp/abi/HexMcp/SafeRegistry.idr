-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- HexMcp.SafeRegistry — Type-safe ABI for hex-mcp cartridge.
--
-- Dependent-type state machine governing Hex.pm API access.
-- Encodes optional API key auth, package search, metadata retrieval,
-- release listing, download stats, dependency analysis, owner listing,
-- retirement checks, and user profile lookup as compile-time invariants.
-- REST API: https://hex.pm/api
-- No unsafe escape hatches.

module HexMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Hex.pm MCP operations.
||| Unauthenticated: no API key; read-only operations available.
||| Authenticated:   Hex API key active, full access.
||| RateLimited:     Hex rate limit hit (429); must wait.
||| Error:           unrecoverable error (invalid key, network failure).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Hex.pm allows both authenticated and unauthenticated sessions.
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
hex_mcp_can_transition : Int -> Int -> Int
hex_mcp_can_transition from to =
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
-- Hex.pm actions
-- ---------------------------------------------------------------------------

||| Actions available through the Hex MCP cartridge.
||| Grouped: Search, Metadata, Releases, Downloads, Dependencies,
||| Owners, Retirement, Users.
public export
data HexAction
  = SearchPackages
  | GetPackage
  | GetRelease
  | ListReleases
  | GetDownloads
  | GetDependencies
  | GetOwners
  | GetRetirement
  | GetUser
  | ListUserPackages

||| Whether an action requires Authenticated state.
||| All Hex.pm read operations work without auth.
export
actionRequiresAuth : HexAction -> Bool
actionRequiresAuth _ = False

||| Whether an action is a write/mutating operation.
||| All hex-mcp actions are read-only queries.
export
actionIsMutating : HexAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : HexAction -> Int
actionToInt SearchPackages   = 0
actionToInt GetPackage       = 1
actionToInt GetRelease       = 2
actionToInt ListReleases     = 3
actionToInt GetDownloads     = 4
actionToInt GetDependencies  = 5
actionToInt GetOwners        = 6
actionToInt GetRetirement    = 7
actionToInt GetUser          = 8
actionToInt ListUserPackages = 9

||| Decode integer to Hex action.
export
intToAction : Int -> Maybe HexAction
intToAction 0 = Just SearchPackages
intToAction 1 = Just GetPackage
intToAction 2 = Just GetRelease
intToAction 3 = Just ListReleases
intToAction 4 = Just GetDownloads
intToAction 5 = Just GetDependencies
intToAction 6 = Just GetOwners
intToAction 7 = Just GetRetirement
intToAction 8 = Just GetUser
intToAction 9 = Just ListUserPackages
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolSearchPackages
  | ToolGetPackage
  | ToolGetRelease
  | ToolListReleases
  | ToolGetDownloads
  | ToolGetDependencies
  | ToolGetOwners
  | ToolGetRetirement
  | ToolGetUser
  | ToolListUserPackages

||| Check if a tool requires an authenticated session.
||| All Hex.pm read operations work without auth.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = False

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 10

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 10
