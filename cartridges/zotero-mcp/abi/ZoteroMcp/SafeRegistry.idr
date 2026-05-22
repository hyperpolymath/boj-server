-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- ZoteroMcp.SafeRegistry — Type-safe ABI for zotero-mcp cartridge.
--
-- Dependent-type state machine governing Zotero Web API v3 access.
-- Encodes mandatory API key auth, library search, item retrieval,
-- collection browsing, tag management, attachment access, citation export,
-- note extraction, saved search execution, group library access, and
-- bibliography generation as compile-time invariants.
-- REST API: https://api.zotero.org
-- No unsafe escape hatches.

module ZoteroMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Zotero MCP operations.
||| Disconnected:  no API key configured or validated.
||| Connected:     authenticated and ready for API calls.
||| RateLimited:   rate limit hit; must wait before retrying.
||| Error:         unrecoverable error (invalid key, network failure).
public export
data SessionState
  = Disconnected
  | Connected
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Zotero requires API key auth — no anonymous access to user libraries.
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
zotero_mcp_can_transition : Int -> Int -> Int
zotero_mcp_can_transition from to =
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
-- Zotero actions
-- ---------------------------------------------------------------------------

||| Actions available through the Zotero MCP cartridge.
||| Grouped: Search, ItemRetrieval, Collections, CollectionItems,
||| Tags, ItemsByTag, Attachments, CitationExport, Notes,
||| SavedSearches, GroupLibraries, Bibliography.
public export
data ZoteroAction
  = SearchItems
  | GetItem
  | ListCollections
  | GetCollectionItems
  | ListTags
  | GetItemsByTag
  | GetAttachments
  | ExportCitation
  | GetNotes
  | ListSavedSearches
  | GetGroupLibraries
  | GenerateBibliography

||| Whether an action requires Connected state.
||| All Zotero operations require an active authenticated session.
export
actionRequiresAuth : ZoteroAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
||| All zotero-mcp actions are read-only queries.
export
actionIsMutating : ZoteroAction -> Bool
actionIsMutating _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : ZoteroAction -> Int
actionToInt SearchItems          = 0
actionToInt GetItem              = 1
actionToInt ListCollections      = 2
actionToInt GetCollectionItems   = 3
actionToInt ListTags             = 4
actionToInt GetItemsByTag        = 5
actionToInt GetAttachments       = 6
actionToInt ExportCitation       = 7
actionToInt GetNotes             = 8
actionToInt ListSavedSearches    = 9
actionToInt GetGroupLibraries    = 10
actionToInt GenerateBibliography = 11

||| Decode integer to Zotero action.
export
intToAction : Int -> Maybe ZoteroAction
intToAction 0  = Just SearchItems
intToAction 1  = Just GetItem
intToAction 2  = Just ListCollections
intToAction 3  = Just GetCollectionItems
intToAction 4  = Just ListTags
intToAction 5  = Just GetItemsByTag
intToAction 6  = Just GetAttachments
intToAction 7  = Just ExportCitation
intToAction 8  = Just GetNotes
intToAction 9  = Just ListSavedSearches
intToAction 10 = Just GetGroupLibraries
intToAction 11 = Just GenerateBibliography
intToAction _  = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolSearchItems
  | ToolGetItem
  | ToolListCollections
  | ToolGetCollectionItems
  | ToolListTags
  | ToolGetItemsByTag
  | ToolGetAttachments
  | ToolExportCitation
  | ToolGetNotes
  | ToolListSavedSearches
  | ToolGetGroupLibraries
  | ToolGenerateBibliography

||| Check if a tool requires a connected session.
||| All Zotero tools require an active authenticated connection.
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
