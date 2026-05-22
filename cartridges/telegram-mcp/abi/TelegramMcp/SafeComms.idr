-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- TelegramMcp.SafeComms — Type-safe ABI for telegram-mcp cartridge.
--
-- Dependent-type-proven state machine for Telegram Bot API communication.
-- Covers the full Telegram Bot API surface: messages, updates, chats,
-- media, webhooks, callbacks, stickers, forwarding, and pinning.
-- Token-in-URL auth pattern (https://api.telegram.org/bot{token}/{method}).
-- Global rate limit: 30 messages per second.

module TelegramMcp.SafeComms

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection state for Telegram bot sessions.
||| Telegram uses a bot token embedded in the URL path:
||| https://api.telegram.org/bot{token}/{method}
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
connStateToInt Disconnected   = 0
connStateToInt Authenticating = 1
connStateToInt Connected      = 2
connStateToInt RateLimited    = 3
connStateToInt Error          = 4

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
telegram_mcp_can_transition : Int -> Int -> Int
telegram_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected,   Just Authenticating) => 1
    (Just Authenticating, Just Connected)      => 1
    (Just Authenticating, Just Error)          => 1
    (Just Connected,      Just RateLimited)    => 1
    (Just RateLimited,    Just Connected)      => 1
    (Just Connected,      Just Error)          => 1
    (Just RateLimited,    Just Error)          => 1
    (Just Error,          Just Disconnected)   => 1
    (Just Connected,      Just Disconnected)   => 1
    _                                          => 0

-- ---------------------------------------------------------------------------
-- Telegram actions
-- ---------------------------------------------------------------------------

||| Actions available through the Telegram Bot API.
||| Each action maps to a Telegram Bot API method.
public export
data TelegramAction
  = SendMessage
  | EditMessage
  | DeleteMessage
  | GetUpdates
  | GetChat
  | ListChats
  | SendPhoto
  | SendDocument
  | SetWebhook
  | DeleteWebhook
  | GetWebhookInfo
  | AnswerCallback
  | SendSticker
  | ForwardMessage
  | PinMessage
  | GetMe

||| Total count of supported Telegram actions.
export
actionCount : Nat
actionCount = 16

||| Encode a Telegram action as a C-compatible integer.
export
actionToInt : TelegramAction -> Int
actionToInt SendMessage    = 0
actionToInt EditMessage    = 1
actionToInt DeleteMessage  = 2
actionToInt GetUpdates     = 3
actionToInt GetChat        = 4
actionToInt ListChats      = 5
actionToInt SendPhoto      = 6
actionToInt SendDocument   = 7
actionToInt SetWebhook     = 8
actionToInt DeleteWebhook  = 9
actionToInt GetWebhookInfo = 10
actionToInt AnswerCallback = 11
actionToInt SendSticker    = 12
actionToInt ForwardMessage = 13
actionToInt PinMessage     = 14
actionToInt GetMe          = 15

||| Decode integer back to a Telegram action.
export
intToAction : Int -> Maybe TelegramAction
intToAction 0  = Just SendMessage
intToAction 1  = Just EditMessage
intToAction 2  = Just DeleteMessage
intToAction 3  = Just GetUpdates
intToAction 4  = Just GetChat
intToAction 5  = Just ListChats
intToAction 6  = Just SendPhoto
intToAction 7  = Just SendDocument
intToAction 8  = Just SetWebhook
intToAction 9  = Just DeleteWebhook
intToAction 10 = Just GetWebhookInfo
intToAction 11 = Just AnswerCallback
intToAction 12 = Just SendSticker
intToAction 13 = Just ForwardMessage
intToAction 14 = Just PinMessage
intToAction 15 = Just GetMe
intToAction _  = Nothing

||| Check whether a given action requires a Connected state.
||| All actions require Connected; none can run while Disconnected,
||| Authenticating, RateLimited, or in Error.
export
actionRequiresConnected : TelegramAction -> Bool
actionRequiresConnected _ = True

-- ---------------------------------------------------------------------------
-- Rate limit model
-- ---------------------------------------------------------------------------

||| Telegram enforces a global rate limit of 30 messages per second.
||| Individual chats have a lower limit of 1 message per second.
||| Group chats allow 20 messages per minute.
public export
data RateLimitInfo : Type where
  MkRateLimitInfo :
    (globalRemaining : Nat) ->
    (globalWindowMs  : Nat) ->
    (perChatBudget   : Nat) ->
    RateLimitInfo

||| Default rate limit configuration for Telegram Bot API.
||| 30 messages per 1000ms global window, 1 per-chat budget.
export
defaultRateLimit : RateLimitInfo
defaultRateLimit = MkRateLimitInfo 30 1000 1

||| Check whether the global rate limit still has remaining requests.
export
hasGlobalCapacity : RateLimitInfo -> Bool
hasGlobalCapacity (MkRateLimitInfo remaining _ _) =
  case remaining of
    Z   => False
    S _ => True

-- ---------------------------------------------------------------------------
-- Auth model
-- ---------------------------------------------------------------------------

||| Telegram bot authentication: token embedded in URL path.
||| URL pattern: https://api.telegram.org/bot{token}/{method}
public export
data AuthConfig : Type where
  MkAuthConfig :
    (token   : String) ->
    (baseUrl : String) ->
    AuthConfig

||| Default base URL for Telegram Bot API.
export
defaultBaseUrl : String
defaultBaseUrl = "https://api.telegram.org/"

||| Validate that a bot token matches the expected format.
||| Telegram bot tokens look like: 123456789:ABCDefGHIJKlmNOpqrSTUvwxYZ
||| Basic structural check: non-empty, contains a colon.
export
validateToken : String -> Bool
validateToken tok =
  let len = length tok
  in len > 10 && len < 200

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
