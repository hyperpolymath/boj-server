-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- CratesMcp.SafeRegistry — Type-safe ABI for crates-mcp cartridge.
--
-- Dependent-type state machine governing crates.io API access.
-- Encodes optional Bearer token auth, crate search, metadata retrieval,
-- version listing, download stats, dependency analysis, reverse deps,
-- owner listing, and category/keyword browsing as compile-time invariants.
-- REST API: https://crates.io/api/v1
-- No unsafe escape hatches.

module CratesMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for crates.io MCP operations.
||| Unauthenticated: no API token; read-only operations available.
||| Authenticated:   crates.io API token active, full access.
||| RateLimited:     crates.io rate limit hit (429); must wait.
||| Error:           unrecoverable error (invalid token, network failure).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| crates.io allows both authenticated and unauthenticated sessions.
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
crates_mcp_can_transition : Int -> Int -> Int
crates_mcp_can_transition from to =
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
    _                                            => 0

-- ---------------------------------------------------------------------------
-- crates.io actions
-- ---------------------------------------------------------------------------

||| Actions available through the crates.io MCP cartridge.
||| Grouped: Search, Metadata, Versions, Downloads, Dependencies,
||| Reverse Dependencies, Owners, Categories, Keywords, Users, Features.
public export
data CratesAction
  = SearchCrates
  | GetCrate
  | GetVersion
  | ListVersions
  | GetDownloads
  | GetDependencies
  | GetReverseDependencies
  | GetOwners
  | ListCategories
  | GetCategory
  | ListKeywords
  | GetUser
  | GetFeatures

||| Whether an action requires Authenticated state.
||| crates.io allows unauthenticated read access for all query operations.
export
actionRequiresAuth : CratesAction -> Bool
actionRequiresAuth _ = False

||| Whether an action is a write/mutating operation.
||| All crates-mcp actions are read-only queries.
export
actionIsMutating : CratesAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : CratesAction -> Int
actionToInt SearchCrates           = 0
actionToInt GetCrate               = 1
actionToInt GetVersion             = 2
actionToInt ListVersions           = 3
actionToInt GetDownloads           = 4
actionToInt GetDependencies        = 5
actionToInt GetReverseDependencies = 6
actionToInt GetOwners              = 7
actionToInt ListCategories         = 8
actionToInt GetCategory            = 9
actionToInt ListKeywords           = 10
actionToInt GetUser                = 11
actionToInt GetFeatures            = 12

||| Decode integer to crates action.
export
intToAction : Int -> Maybe CratesAction
intToAction 0  = Just SearchCrates
intToAction 1  = Just GetCrate
intToAction 2  = Just GetVersion
intToAction 3  = Just ListVersions
intToAction 4  = Just GetDownloads
intToAction 5  = Just GetDependencies
intToAction 6  = Just GetReverseDependencies
intToAction 7  = Just GetOwners
intToAction 8  = Just ListCategories
intToAction 9  = Just GetCategory
intToAction 10 = Just ListKeywords
intToAction 11 = Just GetUser
intToAction 12 = Just GetFeatures
intToAction _  = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolSearchCrates
  | ToolGetCrate
  | ToolGetVersion
  | ToolListVersions
  | ToolGetDownloads
  | ToolGetDependencies
  | ToolGetReverseDependencies
  | ToolGetOwners
  | ToolListCategories
  | ToolGetCategory
  | ToolListKeywords
  | ToolGetUser
  | ToolGetFeatures

||| Check if a tool requires an authenticated session.
||| All crates.io read operations work without auth.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = False

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 13

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 13
