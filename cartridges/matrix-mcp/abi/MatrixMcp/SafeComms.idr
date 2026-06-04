-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- MatrixMcp.SafeComms — Type-safe ABI for matrix-mcp cartridge.
--
-- Dependent-type-proven state machine for Matrix Client-Server API
-- communication. Covers the full Client-Server API v3 surface: messages,
-- events, rooms, membership, state, sync, search, media, profiles, and
-- room creation. Bearer token auth with configurable homeserver URL.
-- Transaction ID generation for idempotent PUT requests.

module MatrixMcp.SafeComms

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for Matrix client sessions.
||| Matrix uses Bearer token authentication against a configurable
||| homeserver URL (default: https://matrix.org) via the
||| Client-Server API (/_matrix/client/v3/).
public export
data ConnState
  = Disconnected
  | Authenticating
  | Connected
  | Syncing
  | Error

||| Proof that a connection state transition is valid.
public export
data ValidTransition : ConnState -> ConnState -> Type where
  StartAuth     : ValidTransition Disconnected Authenticating
  AuthSuccess   : ValidTransition Authenticating Connected
  AuthFail      : ValidTransition Authenticating Error
  BeginSync     : ValidTransition Connected Syncing
  SyncDone      : ValidTransition Syncing Connected
  ConnError     : ValidTransition Connected Error
  SyncError     : ValidTransition Syncing Error
  Recover       : ValidTransition Error Disconnected
  Disconnect    : ValidTransition Connected Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding for ConnState
-- ---------------------------------------------------------------------------

||| Encode connection state as C-compatible integer.
export
connStateToInt : ConnState -> Int
connStateToInt Disconnected   = 0
connStateToInt Authenticating = 1
connStateToInt Connected      = 2
connStateToInt Syncing        = 3
connStateToInt Error          = 4

||| Decode integer back to connection state.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Disconnected
intToConnState 1 = Just Authenticating
intToConnState 2 = Just Connected
intToConnState 3 = Just Syncing
intToConnState 4 = Just Error
intToConnState _ = Nothing

||| Check if a connection state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
matrix_mcp_can_transition : Int -> Int -> Int
matrix_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected,   Just Authenticating) => 1
    (Just Authenticating, Just Connected)      => 1
    (Just Authenticating, Just Error)          => 1
    (Just Connected,      Just Syncing)        => 1
    (Just Syncing,        Just Connected)      => 1
    (Just Connected,      Just Error)          => 1
    (Just Syncing,        Just Error)          => 1
    (Just Error,          Just Disconnected)   => 1
    (Just Connected,      Just Disconnected)   => 1
    _                                          => 0

-- ---------------------------------------------------------------------------
-- Matrix actions
-- ---------------------------------------------------------------------------

||| Actions available through the Matrix Client-Server API v3.
||| Each action maps to one or more Matrix REST endpoints.
public export
data MatrixAction
  = SendMessage
  | SendEvent
  | GetRoom
  | ListRooms
  | JoinRoom
  | LeaveRoom
  | InviteUser
  | KickUser
  | SetRoomState
  | GetRoomState
  | Sync
  | SearchMessages
  | UploadMedia
  | GetProfile
  | SetDisplayName
  | CreateRoom

||| Total count of supported Matrix actions.
export
actionCount : Nat
actionCount = 16

||| Encode a Matrix action as a C-compatible integer.
export
actionToInt : MatrixAction -> Int
actionToInt SendMessage    = 0
actionToInt SendEvent      = 1
actionToInt GetRoom        = 2
actionToInt ListRooms      = 3
actionToInt JoinRoom       = 4
actionToInt LeaveRoom      = 5
actionToInt InviteUser     = 6
actionToInt KickUser       = 7
actionToInt SetRoomState   = 8
actionToInt GetRoomState   = 9
actionToInt Sync           = 10
actionToInt SearchMessages = 11
actionToInt UploadMedia    = 12
actionToInt GetProfile     = 13
actionToInt SetDisplayName = 14
actionToInt CreateRoom     = 15

||| Decode integer back to a Matrix action.
export
intToAction : Int -> Maybe MatrixAction
intToAction 0  = Just SendMessage
intToAction 1  = Just SendEvent
intToAction 2  = Just GetRoom
intToAction 3  = Just ListRooms
intToAction 4  = Just JoinRoom
intToAction 5  = Just LeaveRoom
intToAction 6  = Just InviteUser
intToAction 7  = Just KickUser
intToAction 8  = Just SetRoomState
intToAction 9  = Just GetRoomState
intToAction 10 = Just Sync
intToAction 11 = Just SearchMessages
intToAction 12 = Just UploadMedia
intToAction 13 = Just GetProfile
intToAction 14 = Just SetDisplayName
intToAction 15 = Just CreateRoom
intToAction _  = Nothing

||| Check whether a given action requires a Connected (or Syncing) state.
||| The Sync action itself triggers the Connected -> Syncing transition.
||| All other actions require Connected state.
export
actionRequiresConnected : MatrixAction -> Bool
actionRequiresConnected _ = True

-- ---------------------------------------------------------------------------
-- Transaction ID model
-- ---------------------------------------------------------------------------

||| Matrix uses transaction IDs for idempotent PUT requests.
||| Each event-sending request includes a unique txnId in the URL path.
||| The server deduplicates based on (access_token, txnId) pairs.
public export
data TxnIdConfig : Type where
  MkTxnIdConfig :
    (txnPrefix  : String) ->
    (counter : Nat) ->
    TxnIdConfig

||| Create a default transaction ID configuration.
export
defaultTxnIdConfig : TxnIdConfig
defaultTxnIdConfig = MkTxnIdConfig "boj" 0

||| Increment the transaction ID counter, returning the new config.
export
nextTxnId : TxnIdConfig -> TxnIdConfig
nextTxnId (MkTxnIdConfig txnPrefix counter) = MkTxnIdConfig txnPrefix (S counter)

-- ---------------------------------------------------------------------------
-- Auth model
-- ---------------------------------------------------------------------------

||| Matrix authentication: Bearer token against a configurable homeserver.
||| The Client-Server API lives at /_matrix/client/v3/ on the homeserver.
public export
data AuthConfig : Type where
  MkAuthConfig :
    (token      : String) ->
    (homeserver : String) ->
    AuthConfig

||| Default homeserver URL for Matrix.
export
defaultHomeserver : String
defaultHomeserver = "https://matrix.org"

||| Client-Server API path prefix.
export
apiPrefix : String
apiPrefix = "/_matrix/client/v3/"

||| Validate that a bearer token is non-empty (basic structural check).
export
validateToken : String -> Bool
validateToken tok =
  let len = length tok
  in len > 0 && len < 1000

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol for this cartridge.
public export
data McpTool
  = ToolConnect
  | ToolDisconnect
  | ToolStatus
  | ToolInvoke
  | ToolList

||| Check if a tool requires a connected session.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession ToolConnect    = False
toolRequiresSession ToolDisconnect = True
toolRequiresSession ToolStatus     = False
toolRequiresSession ToolInvoke     = True
toolRequiresSession ToolList       = False

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 5
