-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- NpmRegistryMcp.SafeRegistry — Type-safe ABI for npm-registry-mcp cartridge.
--
-- Dependent-type state machine governing npm registry API access.
-- Encodes Bearer token auth (optional for reads), package search,
-- metadata retrieval, download stats, audit advisories, and
-- provenance attestation queries as compile-time invariants.
-- REST API: https://registry.npmjs.org
-- No unsafe escape hatches.

module NpmRegistryMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for npm registry MCP operations.
||| Unauthenticated: no token loaded; read-only operations available.
||| Authenticated:   npm Bearer token active, full access.
||| RateLimited:     registry rate limit hit; must wait.
||| Error:           unrecoverable error (invalid token, network failure).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Only these transitions are permitted in the session lifecycle.
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

||| Encode session state as C-compatible integer for the Zig FFI boundary.
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
||| Returns 1 for valid, 0 for invalid.
export
npm_registry_mcp_can_transition : Int -> Int -> Int
npm_registry_mcp_can_transition from to =
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
-- npm registry actions
-- ---------------------------------------------------------------------------

||| Actions available through the npm registry MCP cartridge.
||| Grouped: Search, Package metadata, Downloads, Dependencies,
||| Maintainers, Dist-tags, Security, Provenance.
public export
data NpmAction
  = SearchPackages
  | GetPackage
  | GetPackageVersion
  | ListVersions
  | GetDownloads
  | GetDownloadsRange
  | GetDependencies
  | GetMaintainers
  | GetDistTags
  | GetAuditAdvisories
  | GetProvenance
  | GetPackument

||| Whether an action requires Authenticated state.
||| npm registry allows unauthenticated read access for most operations.
export
actionRequiresAuth : NpmAction -> Bool
actionRequiresAuth _ = False

||| Whether an action is a write/mutating operation.
||| All npm-registry-mcp actions are read-only queries.
export
actionIsMutating : NpmAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : NpmAction -> Int
actionToInt SearchPackages    = 0
actionToInt GetPackage        = 1
actionToInt GetPackageVersion = 2
actionToInt ListVersions      = 3
actionToInt GetDownloads      = 4
actionToInt GetDownloadsRange = 5
actionToInt GetDependencies   = 6
actionToInt GetMaintainers    = 7
actionToInt GetDistTags       = 8
actionToInt GetAuditAdvisories = 9
actionToInt GetProvenance     = 10
actionToInt GetPackument      = 11

||| Decode integer to npm action.
export
intToAction : Int -> Maybe NpmAction
intToAction 0  = Just SearchPackages
intToAction 1  = Just GetPackage
intToAction 2  = Just GetPackageVersion
intToAction 3  = Just ListVersions
intToAction 4  = Just GetDownloads
intToAction 5  = Just GetDownloadsRange
intToAction 6  = Just GetDependencies
intToAction 7  = Just GetMaintainers
intToAction 8  = Just GetDistTags
intToAction 9  = Just GetAuditAdvisories
intToAction 10 = Just GetProvenance
intToAction 11 = Just GetPackument
intToAction _  = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolSearchPackages
  | ToolGetPackage
  | ToolGetPackageVersion
  | ToolListVersions
  | ToolGetDownloads
  | ToolGetDownloadsRange
  | ToolGetDependencies
  | ToolGetMaintainers
  | ToolGetDistTags
  | ToolGetAuditAdvisories
  | ToolGetProvenance
  | ToolGetPackument

||| Check if a tool requires an authenticated session.
||| All npm registry read operations work without auth.
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
