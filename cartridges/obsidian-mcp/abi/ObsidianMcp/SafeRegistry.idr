-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- ObsidianMcp.SafeRegistry — Type-safe ABI for obsidian-mcp cartridge.
--
-- Dependent-type state machine governing Obsidian Local REST API access.
-- Encodes mandatory Bearer token auth, note search, content retrieval,
-- backlink navigation, tag browsing, graph analysis, dataview queries,
-- frontmatter extraction, daily notes, template listing, and vault
-- statistics as compile-time invariants.
-- REST API: https://127.0.0.1:27124
-- No unsafe escape hatches.

module ObsidianMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Obsidian MCP operations.
||| Disconnected:  no connection to Obsidian REST API.
||| Connected:     authenticated and connected to Obsidian instance.
||| RateLimited:   rate limit hit; must wait.
||| Error:         unrecoverable error (Obsidian not running, bad key).
||| Note: Obsidian REST API always requires auth (no anonymous mode).
public export
data SessionState
  = Disconnected
  | Connected
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Obsidian requires auth — no anonymous sessions.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Connect        : ValidTransition Disconnected Connected
  Disconnect     : ValidTransition Connected Disconnected
  Throttle       : ValidTransition Connected RateLimited
  Unthrottle     : ValidTransition RateLimited Connected
  ConnectError   : ValidTransition Connected Error
  DisconnError   : ValidTransition Disconnected Error
  RecoverConnect : ValidTransition Error Connected
  RecoverDisconn : ValidTransition Error Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer for FFI boundary.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Disconnected = 0
sessionStateToInt Connected    = 1
sessionStateToInt RateLimited  = 2
sessionStateToInt Error        = 3

||| Decode integer back to session state. Returns Nothing for out-of-range.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Disconnected
intToSessionState 1 = Just Connected
intToSessionState 2 = Just RateLimited
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
export
obsidian_mcp_can_transition : Int -> Int -> Int
obsidian_mcp_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just Connected,    Just RateLimited)  => 1
    (Just RateLimited,  Just Connected)    => 1
    (Just Connected,    Just Error)        => 1
    (Just Disconnected, Just Error)        => 1
    (Just Error,        Just Connected)    => 1
    (Just Error,        Just Disconnected) => 1
    _                                     => 0

-- ---------------------------------------------------------------------------
-- Obsidian actions
-- ---------------------------------------------------------------------------

||| Actions available through the Obsidian MCP cartridge.
||| Grouped: Search, Content, Listing, Backlinks, OutgoingLinks,
||| Tags, NotesByTag, Frontmatter, DailyNotes, VaultStats,
||| Dataview, Templates.
public export
data ObsidianAction
  = SearchNotes
  | GetNote
  | ListNotes
  | GetBacklinks
  | GetOutgoingLinks
  | ListTags
  | GetNotesByTag
  | GetFrontmatter
  | GetDailyNote
  | VaultStats
  | DataviewQuery
  | ListTemplates

||| Whether an action requires Connected state.
||| All Obsidian operations require an active connection.
export
actionRequiresAuth : ObsidianAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
||| All obsidian-mcp actions are read-only queries.
export
actionIsMutating : ObsidianAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : ObsidianAction -> Int
actionToInt SearchNotes      = 0
actionToInt GetNote          = 1
actionToInt ListNotes        = 2
actionToInt GetBacklinks     = 3
actionToInt GetOutgoingLinks = 4
actionToInt ListTags         = 5
actionToInt GetNotesByTag    = 6
actionToInt GetFrontmatter   = 7
actionToInt GetDailyNote     = 8
actionToInt VaultStats       = 9
actionToInt DataviewQuery    = 10
actionToInt ListTemplates    = 11

||| Decode integer to Obsidian action.
export
intToAction : Int -> Maybe ObsidianAction
intToAction 0  = Just SearchNotes
intToAction 1  = Just GetNote
intToAction 2  = Just ListNotes
intToAction 3  = Just GetBacklinks
intToAction 4  = Just GetOutgoingLinks
intToAction 5  = Just ListTags
intToAction 6  = Just GetNotesByTag
intToAction 7  = Just GetFrontmatter
intToAction 8  = Just GetDailyNote
intToAction 9  = Just VaultStats
intToAction 10 = Just DataviewQuery
intToAction 11 = Just ListTemplates
intToAction _  = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolSearchNotes
  | ToolGetNote
  | ToolListNotes
  | ToolGetBacklinks
  | ToolGetOutgoingLinks
  | ToolListTags
  | ToolGetNotesByTag
  | ToolGetFrontmatter
  | ToolGetDailyNote
  | ToolVaultStats
  | ToolDataviewQuery
  | ToolListTemplates

||| Check if a tool requires a connected session.
||| All Obsidian tools require an active authenticated connection.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = True

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 12

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 12
