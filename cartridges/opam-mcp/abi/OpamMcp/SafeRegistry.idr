-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- OpamMcp.SafeRegistry — Type-safe ABI for opam-mcp cartridge.
--
-- Dependent-type state machine governing opam.ocaml.org API access.
-- Encodes package search, metadata retrieval, version listing,
-- dependency analysis, reverse dependency lookup, maintainer listing,
-- tag retrieval, full package listing, and raw opam file access
-- as compile-time invariants.
-- REST API: https://opam.ocaml.org/api
-- No unsafe escape hatches. No auth required (fully public registry).

module OpamMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Session state machine
-- ---------------------------------------------------------------------------

||| Session state for opam MCP operations.
||| Active:      session is operational, ready for queries.
||| RateLimited: opam.ocaml.org rate limit hit (429); must wait.
||| Error:       unrecoverable error (network failure).
||| Note: opam has no auth, so Active replaces Unauthenticated/Authenticated.
public export
data SessionState
  = Active
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| opam is always public — no auth transitions needed.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Throttle       : ValidTransition Active RateLimited
  Unthrottle     : ValidTransition RateLimited Active
  SignalError    : ValidTransition Active Error
  RecoverToActive : ValidTransition Error Active

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer for FFI boundary.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Active      = 0
sessionStateToInt RateLimited = 1
sessionStateToInt Error       = 2

||| Decode integer back to session state. Returns Nothing for out-of-range.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Active
intToSessionState 1 = Just RateLimited
intToSessionState 2 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
export
opam_mcp_can_transition : Int -> Int -> Int
opam_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Active,      Just RateLimited) => 1
    (Just RateLimited, Just Active)      => 1
    (Just Active,      Just Error)       => 1
    (Just Error,       Just Active)      => 1
    _                                   => 0

-- ---------------------------------------------------------------------------
-- opam actions
-- ---------------------------------------------------------------------------

||| Actions available through the opam MCP cartridge.
||| Grouped: Search, Metadata, Versions, Dependencies, ReverseDeps,
||| Maintainers, Tags, ListAll, OpamFile.
public export
data OpamAction
  = SearchPackages
  | GetPackage
  | GetVersion
  | ListVersions
  | GetDependencies
  | GetReverseDependencies
  | GetMaintainers
  | GetTags
  | ListAllPackages
  | GetOpamFile

||| Whether an action requires authentication.
||| opam is fully public — no auth required for any action.
export
actionRequiresAuth : OpamAction -> Bool
actionRequiresAuth _ = False

||| Whether an action is a write/mutating operation.
||| All opam-mcp actions are read-only queries.
export
actionIsMutating : OpamAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : OpamAction -> Int
actionToInt SearchPackages        = 0
actionToInt GetPackage            = 1
actionToInt GetVersion            = 2
actionToInt ListVersions          = 3
actionToInt GetDependencies       = 4
actionToInt GetReverseDependencies = 5
actionToInt GetMaintainers        = 6
actionToInt GetTags               = 7
actionToInt ListAllPackages       = 8
actionToInt GetOpamFile           = 9

||| Decode integer to opam action.
export
intToAction : Int -> Maybe OpamAction
intToAction 0 = Just SearchPackages
intToAction 1 = Just GetPackage
intToAction 2 = Just GetVersion
intToAction 3 = Just ListVersions
intToAction 4 = Just GetDependencies
intToAction 5 = Just GetReverseDependencies
intToAction 6 = Just GetMaintainers
intToAction 7 = Just GetTags
intToAction 8 = Just ListAllPackages
intToAction 9 = Just GetOpamFile
intToAction _ = Nothing

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
  | ToolGetDependencies
  | ToolGetReverseDependencies
  | ToolGetMaintainers
  | ToolGetTags
  | ToolListAllPackages
  | ToolGetOpamFile

||| Check if a tool requires an active session.
||| opam is always public.
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
