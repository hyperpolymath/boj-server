-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- PypiMcp.SafeRegistry — Type-safe ABI for pypi-mcp cartridge.
--
-- Dependent-type state machine governing PyPI API access.
-- Encodes optional Bearer token auth, package search, metadata retrieval,
-- version listing, download stats, dependency analysis, release files,
-- maintainer lookup, classifier browsing, vulnerability checks,
-- and project URL extraction as compile-time invariants.
-- REST API: https://pypi.org/pypi/<package>/json
-- No unsafe escape hatches.

module PypiMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for PyPI MCP operations.
||| Unauthenticated: no API token; read-only operations available.
||| Authenticated:   PyPI API token active, full access.
||| RateLimited:     PyPI rate limit hit (429); must wait.
||| Error:           unrecoverable error (invalid token, network failure).
public export
data SessionState
  = Unauthenticated
  | Authenticated
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| PyPI allows both authenticated and unauthenticated sessions.
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
pypi_mcp_can_transition : Int -> Int -> Int
pypi_mcp_can_transition from to =
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
-- PyPI actions
-- ---------------------------------------------------------------------------

||| Actions available through the PyPI MCP cartridge.
||| Grouped: Search, Metadata, Versions, Downloads, Dependencies,
||| ReleaseFiles, Maintainers, Classifiers, Vulnerabilities, ProjectURLs.
public export
data PypiAction
  = SearchPackages
  | GetPackage
  | GetVersion
  | ListVersions
  | GetDownloads
  | GetDependencies
  | GetReleaseFiles
  | GetMaintainers
  | GetClassifiers
  | GetVulnerabilities
  | GetProjectUrls

||| Whether an action requires Authenticated state.
||| All PyPI read operations work without auth.
export
actionRequiresAuth : PypiAction -> Bool
actionRequiresAuth _ = False

||| Whether an action is a write/mutating operation.
||| All pypi-mcp actions are read-only queries.
export
actionIsMutating : PypiAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : PypiAction -> Int
actionToInt SearchPackages     = 0
actionToInt GetPackage         = 1
actionToInt GetVersion         = 2
actionToInt ListVersions       = 3
actionToInt GetDownloads       = 4
actionToInt GetDependencies    = 5
actionToInt GetReleaseFiles    = 6
actionToInt GetMaintainers     = 7
actionToInt GetClassifiers     = 8
actionToInt GetVulnerabilities = 9
actionToInt GetProjectUrls     = 10

||| Decode integer to PyPI action.
export
intToAction : Int -> Maybe PypiAction
intToAction 0  = Just SearchPackages
intToAction 1  = Just GetPackage
intToAction 2  = Just GetVersion
intToAction 3  = Just ListVersions
intToAction 4  = Just GetDownloads
intToAction 5  = Just GetDependencies
intToAction 6  = Just GetReleaseFiles
intToAction 7  = Just GetMaintainers
intToAction 8  = Just GetClassifiers
intToAction 9  = Just GetVulnerabilities
intToAction 10 = Just GetProjectUrls
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
  | ToolGetReleaseFiles
  | ToolGetMaintainers
  | ToolGetClassifiers
  | ToolGetVulnerabilities
  | ToolGetProjectUrls

||| Check if a tool requires an authenticated session.
||| All PyPI read operations work without auth.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = False

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 11

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 11
