-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- GoogleDocsMcp.SafeRegistry — Type-safe ABI for google-docs-mcp cartridge.
--
-- Dependent-type state machine governing Google Docs API v1 access.
-- Encodes mandatory OAuth2 auth, document retrieval, content reading,
-- text search, heading extraction, comment listing, suggestion browsing,
-- revision history, named range access, document creation, and text
-- insertion as compile-time invariants.
-- REST API: https://docs.googleapis.com/v1
-- No unsafe escape hatches.

module GoogleDocsMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Google Docs MCP operations.
||| Disconnected:  no OAuth2 token configured.
||| Connected:     authenticated and ready for API calls.
||| RateLimited:   rate limit hit; must wait before retrying.
||| Error:         unrecoverable error (expired token, permission denied).
public export
data SessionState
  = Disconnected
  | Connected
  | RateLimited
  | Error

||| Proof that a state transition is valid.
||| Google Docs requires OAuth2 auth — no anonymous access.
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
google_docs_mcp_can_transition : Int -> Int -> Int
google_docs_mcp_can_transition from to =
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
-- Google Docs actions
-- ---------------------------------------------------------------------------

||| Actions available through the Google Docs MCP cartridge.
||| Grouped: GetDocument, GetContent, GetHeadings, SearchContent,
||| ListComments, ListSuggestions, GetRevisions, GetNamedRanges,
||| CreateDocument, InsertText.
public export
data GoogleDocsAction
  = GetDocument
  | GetContent
  | GetHeadings
  | SearchContent
  | ListComments
  | ListSuggestions
  | GetRevisions
  | GetNamedRanges
  | CreateDocument
  | InsertText

||| Whether an action requires Connected state.
||| All Google Docs operations require an active authenticated session.
export
actionRequiresAuth : GoogleDocsAction -> Bool
actionRequiresAuth _ = True

||| Whether an action is a write/mutating operation.
||| CreateDocument and InsertText are mutating; all others are read-only.
export
actionIsMutating : GoogleDocsAction -> Bool
actionIsMutating CreateDocument = True
actionIsMutating InsertText     = True
actionIsMutating _              = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : GoogleDocsAction -> Int
actionToInt GetDocument     = 0
actionToInt GetContent      = 1
actionToInt GetHeadings     = 2
actionToInt SearchContent   = 3
actionToInt ListComments    = 4
actionToInt ListSuggestions = 5
actionToInt GetRevisions    = 6
actionToInt GetNamedRanges  = 7
actionToInt CreateDocument  = 8
actionToInt InsertText      = 9

||| Decode integer to Google Docs action.
export
intToAction : Int -> Maybe GoogleDocsAction
intToAction 0 = Just GetDocument
intToAction 1 = Just GetContent
intToAction 2 = Just GetHeadings
intToAction 3 = Just SearchContent
intToAction 4 = Just ListComments
intToAction 5 = Just ListSuggestions
intToAction 6 = Just GetRevisions
intToAction 7 = Just GetNamedRanges
intToAction 8 = Just CreateDocument
intToAction 9 = Just InsertText
intToAction _ = Nothing

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolGetDocument
  | ToolGetContent
  | ToolGetHeadings
  | ToolSearchContent
  | ToolListComments
  | ToolListSuggestions
  | ToolGetRevisions
  | ToolGetNamedRanges
  | ToolCreateDocument
  | ToolInsertText

||| Check if a tool requires a connected session.
||| All Google Docs tools require an active authenticated connection.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = True

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 10

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 10
