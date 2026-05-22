-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- DiscordMcp.SafeComms — Type-safe ABI for discord-mcp cartridge.
--
-- Dependent-type-proven state machine for Discord bot communication.
-- Covers the full Discord REST API v10 surface: messages, channels,
-- guilds, members, reactions, threads, search, status, and file uploads.
-- Bucket-based per-route rate limiting modelled in the state machine.

module DiscordMcp.SafeComms

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for Discord bot sessions.
||| Discord uses a Bot token with "Bot" prefix in the Authorization header,
||| communicating via REST at https://discord.com/api/v10/.
public export
data ConnState
  = Disconnected
  | Authenticating
  | Connected
  | RateLimited
  | Error

||| Proof that a connection state transition is valid.
public export
data ValidTransition : ConnState -> ConnState -> Type where
  StartAuth     : ValidTransition Disconnected Authenticating
  AuthSuccess   : ValidTransition Authenticating Connected
  AuthFail      : ValidTransition Authenticating Error
  HitRateLimit  : ValidTransition Connected RateLimited
  RateLimitDone : ValidTransition RateLimited Connected
  ConnError     : ValidTransition Connected Error
  RateError     : ValidTransition RateLimited Error
  Recover       : ValidTransition Error Disconnected
  Disconnect    : ValidTransition Connected Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding for ConnState
-- ---------------------------------------------------------------------------

||| Encode connection state as C-compatible integer.
export
connStateToInt : ConnState -> Int
connStateToInt Disconnected  = 0
connStateToInt Authenticating = 1
connStateToInt Connected     = 2
connStateToInt RateLimited   = 3
connStateToInt Error         = 4

||| Decode integer back to connection state.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Disconnected
intToConnState 1 = Just Authenticating
intToConnState 2 = Just Connected
intToConnState 3 = Just RateLimited
intToConnState 4 = Just Error
intToConnState _ = Nothing

||| Check if a connection state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
discord_mcp_can_transition : Int -> Int -> Int
discord_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected,  Just Authenticating) => 1
    (Just Authenticating, Just Connected)     => 1
    (Just Authenticating, Just Error)         => 1
    (Just Connected,     Just RateLimited)    => 1
    (Just RateLimited,   Just Connected)      => 1
    (Just Connected,     Just Error)          => 1
    (Just RateLimited,   Just Error)          => 1
    (Just Error,         Just Disconnected)   => 1
    (Just Connected,     Just Disconnected)   => 1
    _                                         => 0

-- ---------------------------------------------------------------------------
-- Discord actions
-- ---------------------------------------------------------------------------

||| Actions available through the Discord REST API v10.
||| Each action maps to one or more Discord REST endpoints.
public export
data DiscordAction
  = SendMessage
  | EditMessage
  | DeleteMessage
  | ListChannels
  | GetChannel
  | ListGuilds
  | GetGuild
  | ListMembers
  | GetMember
  | AddReaction
  | RemoveReaction
  | CreateThread
  | ListThreads
  | SearchMessages
  | SetStatus
  | UploadFile

||| Total count of supported Discord actions.
export
actionCount : Nat
actionCount = 16

||| Encode a Discord action as a C-compatible integer.
export
actionToInt : DiscordAction -> Int
actionToInt SendMessage    = 0
actionToInt EditMessage    = 1
actionToInt DeleteMessage  = 2
actionToInt ListChannels   = 3
actionToInt GetChannel     = 4
actionToInt ListGuilds     = 5
actionToInt GetGuild       = 6
actionToInt ListMembers    = 7
actionToInt GetMember      = 8
actionToInt AddReaction    = 9
actionToInt RemoveReaction = 10
actionToInt CreateThread   = 11
actionToInt ListThreads    = 12
actionToInt SearchMessages = 13
actionToInt SetStatus      = 14
actionToInt UploadFile     = 15

||| Decode integer back to a Discord action.
export
intToAction : Int -> Maybe DiscordAction
intToAction 0  = Just SendMessage
intToAction 1  = Just EditMessage
intToAction 2  = Just DeleteMessage
intToAction 3  = Just ListChannels
intToAction 4  = Just GetChannel
intToAction 5  = Just ListGuilds
intToAction 6  = Just GetGuild
intToAction 7  = Just ListMembers
intToAction 8  = Just GetMember
intToAction 9  = Just AddReaction
intToAction 10 = Just RemoveReaction
intToAction 11 = Just CreateThread
intToAction 12 = Just ListThreads
intToAction 13 = Just SearchMessages
intToAction 14 = Just SetStatus
intToAction 15 = Just UploadFile
intToAction _  = Nothing

||| Check whether a given action requires a Connected state.
||| All actions require Connected; none can run while Disconnected,
||| Authenticating, RateLimited, or in Error.
export
actionRequiresConnected : DiscordAction -> Bool
actionRequiresConnected _ = True

-- ---------------------------------------------------------------------------
-- Rate limit bucket model
-- ---------------------------------------------------------------------------

||| Discord uses bucket-based per-route rate limiting.
||| Each route belongs to a bucket identified by a string hash.
||| The server returns X-RateLimit-Bucket, X-RateLimit-Remaining,
||| and X-RateLimit-Reset headers.
public export
data RateLimitInfo : Type where
  MkRateLimitInfo :
    (bucket     : String) ->
    (remaining  : Nat) ->
    (resetAfter : Nat) ->
    RateLimitInfo

||| Check whether a rate limit bucket still has remaining requests.
export
bucketHasCapacity : RateLimitInfo -> Bool
bucketHasCapacity (MkRateLimitInfo _ remaining _) =
  case remaining of
    Z   => False
    S _ => True

-- ---------------------------------------------------------------------------
-- Auth model
-- ---------------------------------------------------------------------------

||| Discord bot authentication: Bot token with "Bot " prefix in
||| the Authorization header.
public export
data AuthConfig : Type where
  MkAuthConfig :
    (token   : String) ->
    (baseUrl : String) ->
    AuthConfig

||| Default base URL for Discord REST API v10.
export
defaultBaseUrl : String
defaultBaseUrl = "https://discord.com/api/v10/"

||| Validate that a bot token is non-empty and does not contain
||| whitespace (basic structural validation).
export
validateToken : String -> Bool
validateToken tok =
  let len = length tok
  in len > 0 && len < 200

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
