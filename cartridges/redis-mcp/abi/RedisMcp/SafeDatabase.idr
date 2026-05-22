-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- RedisMcp.SafeDatabase -- Type-safe ABI for redis-mcp cartridge.
--
-- Dependently-typed state machine modelling Redis connection lifecycle.
-- Transitions are proven valid at compile time. Authentication via AUTH
-- command with password sourced from vault-mcp. Supports RESP protocol
-- including pipeline and pub/sub modes.

module RedisMcp.SafeDatabase

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Redis connection lifecycle states.
|||
||| @ Disconnected  No active connection to the Redis server.
||| @ Connected     Authenticated connection established; ready for commands.
||| @ Subscribing   In pub/sub subscriber mode (limited command set).
||| @ Error         An error has occurred; must disconnect to recover.
public export
data ConnState
  = Disconnected
  | Connected
  | Subscribing
  | Error

||| Proof that a state transition is valid within the Redis protocol.
|||
||| The transition graph:
|||   Disconnected -> Connected    (connect + AUTH)
|||   Connected    -> Subscribing  (SUBSCRIBE)
|||   Subscribing  -> Connected    (UNSUBSCRIBE all)
|||   Connected    -> Error        (connection or protocol error)
|||   Subscribing  -> Error        (connection error during sub)
|||   Error        -> Disconnected (disconnect after error)
|||   Connected    -> Disconnected (graceful disconnect)
public export
data ValidTransition : ConnState -> ConnState -> Type where
  Connect       : ValidTransition Disconnected Connected
  Disconnect    : ValidTransition Connected Disconnected
  Subscribe     : ValidTransition Connected Subscribing
  Unsubscribe   : ValidTransition Subscribing Connected
  ConnError     : ValidTransition Connected Error
  SubError      : ValidTransition Subscribing Error
  ErrorReset    : ValidTransition Error Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode connection state as C-compatible integer.
export
connStateToInt : ConnState -> Int
connStateToInt Disconnected = 0
connStateToInt Connected    = 1
connStateToInt Subscribing  = 2
connStateToInt Error        = 3

||| Decode integer back to connection state.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Disconnected
intToConnState 1 = Just Connected
intToConnState 2 = Just Subscribing
intToConnState 3 = Just Error
intToConnState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
redis_mcp_can_transition : Int -> Int -> Int
redis_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected, Just Connected)    => 1
    (Just Connected,    Just Disconnected) => 1
    (Just Connected,    Just Subscribing)  => 1
    (Just Subscribing,  Just Connected)    => 1
    (Just Connected,    Just Error)        => 1
    (Just Subscribing,  Just Error)        => 1
    (Just Error,        Just Disconnected) => 1
    _                                      => 0

-- ---------------------------------------------------------------------------
-- Redis actions
-- ---------------------------------------------------------------------------

||| Actions exposed via the redis-mcp MCP protocol.
|||
||| All 20 operations supported by this cartridge, covering strings, lists,
||| sets, hashes, pub/sub, TTL management, and server introspection.
public export
data RedisAction
  = Get
  | Set
  | Del
  | Keys
  | Exists
  | Expire
  | TTL
  | LPush
  | RPush
  | LRange
  | SAdd
  | SMembers
  | HSet
  | HGet
  | HGetAll
  | Publish
  | SubscribeAction
  | UnsubscribeAction
  | Info
  | Ping

||| Encode action as C-compatible integer.
export
actionToInt : RedisAction -> Int
actionToInt Get               = 0
actionToInt Set               = 1
actionToInt Del               = 2
actionToInt Keys              = 3
actionToInt Exists            = 4
actionToInt Expire            = 5
actionToInt TTL               = 6
actionToInt LPush             = 7
actionToInt RPush             = 8
actionToInt LRange            = 9
actionToInt SAdd              = 10
actionToInt SMembers          = 11
actionToInt HSet              = 12
actionToInt HGet              = 13
actionToInt HGetAll           = 14
actionToInt Publish           = 15
actionToInt SubscribeAction   = 16
actionToInt UnsubscribeAction = 17
actionToInt Info              = 18
actionToInt Ping              = 19

||| Decode integer back to action.
export
intToAction : Int -> Maybe RedisAction
intToAction 0  = Just Get
intToAction 1  = Just Set
intToAction 2  = Just Del
intToAction 3  = Just Keys
intToAction 4  = Just Exists
intToAction 5  = Just Expire
intToAction 6  = Just TTL
intToAction 7  = Just LPush
intToAction 8  = Just RPush
intToAction 9  = Just LRange
intToAction 10 = Just SAdd
intToAction 11 = Just SMembers
intToAction 12 = Just HSet
intToAction 13 = Just HGet
intToAction 14 = Just HGetAll
intToAction 15 = Just Publish
intToAction 16 = Just SubscribeAction
intToAction 17 = Just UnsubscribeAction
intToAction 18 = Just Info
intToAction 19 = Just Ping
intToAction _  = Nothing

||| Check whether an action requires an active connection.
export
actionRequiresConnection : RedisAction -> Bool
actionRequiresConnection Ping = False
actionRequiresConnection _    = True

||| Check whether an action is only valid in Subscribing state.
export
actionRequiresSubscribing : RedisAction -> Bool
actionRequiresSubscribing UnsubscribeAction = True
actionRequiresSubscribing _                 = False

||| Check whether an action enters Subscribing state.
export
actionEntersSubscribing : RedisAction -> Bool
actionEntersSubscribing SubscribeAction = True
actionEntersSubscribing _               = False

||| Total number of actions in this cartridge.
export
actionCount : Nat
actionCount = 20

-- ---------------------------------------------------------------------------
-- Authentication
-- ---------------------------------------------------------------------------

||| Authentication method for Redis connections.
||| Password sourced from vault-mcp via AUTH command to host:6379.
public export
data AuthMethod
  = AuthPassword
  | VaultRef String

-- ---------------------------------------------------------------------------
-- RESP protocol types
-- ---------------------------------------------------------------------------

||| Redis RESP (REdis Serialization Protocol) wire types.
public export
data RespType
  = SimpleString
  | RespError
  | RespInteger
  | BulkString
  | RespArray
  | RespNull

||| Encode RESP type as C-compatible integer.
export
respTypeToInt : RespType -> Int
respTypeToInt SimpleString = 0
respTypeToInt RespError    = 1
respTypeToInt RespInteger  = 2
respTypeToInt BulkString   = 3
respTypeToInt RespArray    = 4
respTypeToInt RespNull     = 5

||| Decode integer back to RESP type.
export
intToRespType : Int -> Maybe RespType
intToRespType 0 = Just SimpleString
intToRespType 1 = Just RespError
intToRespType 2 = Just RespInteger
intToRespType 3 = Just BulkString
intToRespType 4 = Just RespArray
intToRespType 5 = Just RespNull
intToRespType _ = Nothing
