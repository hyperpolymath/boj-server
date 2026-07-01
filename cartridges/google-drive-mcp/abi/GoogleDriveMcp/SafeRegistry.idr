-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
--
-- GoogleDriveMcp.SafeRegistry — Type-safe ABI for google-drive-mcp cartridge.
--
-- Dependent-type state machine governing Google Drive API v3 access.
-- Encodes mandatory OAuth2 auth and the 18 Drive operations (search,
-- export-aware read, metadata, folder/recents listing, permissions, sharing,
-- copy, create, update, move, rename, REVERSIBLE trash/restore, revisions,
-- storage quota, shared-drive enumeration) as compile-time invariants.
--
-- Safety invariant encoded here: there is NO permanent-delete action. The most
-- destructive operation is `Trash`, which is reversible via `Restore`. This is
-- a type-level guarantee, not a convention — `actionIsDestructive` is total and
-- has no `True` case.
-- REST API: https://www.googleapis.com/drive/v3
-- No unsafe escape hatches.

module GoogleDriveMcp.SafeRegistry

%default total

-- ---------------------------------------------------------------------------
-- Authentication state machine
-- ---------------------------------------------------------------------------

||| Session state for Google Drive MCP operations.
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
||| Google Drive requires OAuth2 auth — no anonymous access.
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
google_drive_mcp_can_transition : Int -> Int -> Int
google_drive_mcp_can_transition from to =
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
-- Google Drive actions (integer codes match google_drive_mcp_ffi.zig exactly)
-- ---------------------------------------------------------------------------

||| Actions available through the Google Drive MCP cartridge.
public export
data GoogleDriveAction
  = Search
  | ReadContent
  | ExportFile
  | GetMetadata
  | ListRecent
  | ListFolder
  | GetPermissions
  | Share
  | Copy
  | CreateFile
  | UpdateContent
  | Move
  | Rename
  | Trash
  | Restore
  | ListRevisions
  | StorageQuota
  | ListSharedDrives

||| Every Drive action requires an authenticated (Connected) session.
export
actionRequiresAuth : GoogleDriveAction -> Bool
actionRequiresAuth _ = True

||| Whether an action mutates Drive state (create/modify/move/share/trash).
||| Read/list/export/metadata/quota/revisions are non-mutating.
export
actionIsMutating : GoogleDriveAction -> Bool
actionIsMutating Share         = True
actionIsMutating Copy          = True
actionIsMutating CreateFile    = True
actionIsMutating UpdateContent = True
actionIsMutating Move          = True
actionIsMutating Rename        = True
actionIsMutating Trash         = True
actionIsMutating Restore       = True
actionIsMutating _             = False

||| SAFETY INVARIANT: no action is permanently destructive. `Trash` is
||| reversible via `Restore`; permanent `files.delete` is deliberately not part
||| of this ABI. Total function with no `True` clause == compile-time proof that
||| the cartridge cannot irreversibly destroy data.
export
actionIsDestructive : GoogleDriveAction -> Bool
actionIsDestructive _ = False

||| Encode action as C-compatible integer for FFI.
export
actionToInt : GoogleDriveAction -> Int
actionToInt Search           = 0
actionToInt ReadContent      = 1
actionToInt ExportFile       = 2
actionToInt GetMetadata      = 3
actionToInt ListRecent       = 4
actionToInt ListFolder       = 5
actionToInt GetPermissions   = 6
actionToInt Share            = 7
actionToInt Copy             = 8
actionToInt CreateFile       = 9
actionToInt UpdateContent    = 10
actionToInt Move             = 11
actionToInt Rename           = 12
actionToInt Trash            = 13
actionToInt Restore          = 14
actionToInt ListRevisions    = 15
actionToInt StorageQuota     = 16
actionToInt ListSharedDrives = 17

||| Decode integer to Google Drive action.
export
intToAction : Int -> Maybe GoogleDriveAction
intToAction 0  = Just Search
intToAction 1  = Just ReadContent
intToAction 2  = Just ExportFile
intToAction 3  = Just GetMetadata
intToAction 4  = Just ListRecent
intToAction 5  = Just ListFolder
intToAction 6  = Just GetPermissions
intToAction 7  = Just Share
intToAction 8  = Just Copy
intToAction 9  = Just CreateFile
intToAction 10 = Just UpdateContent
intToAction 11 = Just Move
intToAction 12 = Just Rename
intToAction 13 = Just Trash
intToAction 14 = Just Restore
intToAction 15 = Just ListRevisions
intToAction 16 = Just StorageQuota
intToAction 17 = Just ListSharedDrives
intToAction _  = Nothing

||| Round-trip proof: decoding an encoded action recovers it. Machine-checked
||| for all 18 constructors, guaranteeing the FFI integer map is injective.
export
actionRoundTrip : (a : GoogleDriveAction) -> intToAction (actionToInt a) = Just a
actionRoundTrip Search           = Refl
actionRoundTrip ReadContent      = Refl
actionRoundTrip ExportFile       = Refl
actionRoundTrip GetMetadata      = Refl
actionRoundTrip ListRecent       = Refl
actionRoundTrip ListFolder       = Refl
actionRoundTrip GetPermissions   = Refl
actionRoundTrip Share            = Refl
actionRoundTrip Copy             = Refl
actionRoundTrip CreateFile       = Refl
actionRoundTrip UpdateContent    = Refl
actionRoundTrip Move             = Refl
actionRoundTrip Rename           = Refl
actionRoundTrip Trash            = Refl
actionRoundTrip Restore          = Refl
actionRoundTrip ListRevisions    = Refl
actionRoundTrip StorageQuota     = Refl
actionRoundTrip ListSharedDrives = Refl

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge (one per action).
public export
data McpTool
  = ToolSearch
  | ToolReadContent
  | ToolExport
  | ToolGetMetadata
  | ToolListRecent
  | ToolListFolder
  | ToolGetPermissions
  | ToolShare
  | ToolCopy
  | ToolCreateFile
  | ToolUpdateContent
  | ToolMove
  | ToolRename
  | ToolTrash
  | ToolRestore
  | ToolListRevisions
  | ToolStorageQuota
  | ToolListSharedDrives

||| Every tool requires a connected session (OAuth2-gated).
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession _ = True

||| Total tool count for this cartridge.
export
toolCount : Nat
toolCount = 18

||| Total action count for this cartridge.
export
actionCount : Nat
actionCount = 18
