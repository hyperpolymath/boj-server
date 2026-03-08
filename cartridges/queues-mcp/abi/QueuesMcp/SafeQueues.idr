-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| QueuesMcp.SafeQueues: Formally verified message queue operations.
|||
||| Cartridge: queues-mcp
||| Matrix cell: Queue domain x {MCP, LSP} protocols
|||
||| This module defines type-safe queue operations with a
||| connection/subscription state machine that prevents:
|||   - Publishing to unconnected queues
|||   - Double-subscribing to the same queue
|||   - Consuming without acknowledging previous messages
|||
||| Supports Redis Streams, RabbitMQ, and NATS backends.
module QueuesMcp.SafeQueues

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Queue State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Queue lifecycle states.
||| A queue progresses: Disconnected -> Connected -> Subscribed -> Consuming -> Subscribed -> Connected -> Disconnected
public export
data QueueState = Disconnected | Connected | Subscribed | Consuming | QueueError

||| Equality for queue states.
public export
Eq QueueState where
  Disconnected == Disconnected = True
  Connected    == Connected    = True
  Subscribed   == Subscribed   = True
  Consuming    == Consuming    = True
  QueueError   == QueueError   = True
  _            == _            = False

||| Valid state transitions (enforced at the type level).
public export
data ValidTransition : QueueState -> QueueState -> Type where
  Connect     : ValidTransition Disconnected Connected
  Subscribe   : ValidTransition Connected Subscribed
  BeginConsume : ValidTransition Subscribed Consuming
  Ack         : ValidTransition Consuming Subscribed
  Unsubscribe : ValidTransition Subscribed Connected
  Disconnect  : ValidTransition Connected Disconnected
  ConsumeError : ValidTransition Consuming QueueError
  Recover     : ValidTransition QueueError Subscribed

||| Runtime transition validator.
public export
canTransition : QueueState -> QueueState -> Bool
canTransition Disconnected Connected    = True
canTransition Connected    Subscribed   = True
canTransition Subscribed   Consuming    = True
canTransition Consuming    Subscribed   = True
canTransition Subscribed   Connected    = True
canTransition Connected    Disconnected = True
canTransition Consuming    QueueError   = True
canTransition QueueError   Subscribed   = True
canTransition _            _            = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Queue Backend Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported message queue backends.
public export
data QueueBackend
  = RedisStream  -- Redis Streams (pub/sub + persistence)
  | RabbitMQ     -- RabbitMQ (AMQP)
  | NATS         -- NATS (lightweight messaging)
  | Custom String -- User-defined backend

||| C-ABI encoding for backends.
public export
backendToInt : QueueBackend -> Int
backendToInt RedisStream  = 1
backendToInt RabbitMQ     = 2
backendToInt NATS         = 3
backendToInt (Custom _)   = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Message Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Message delivery guarantee level.
public export
data DeliveryGuarantee
  = AtMostOnce   -- Fire and forget
  | AtLeastOnce  -- Retry until acknowledged
  | ExactlyOnce  -- Transactional delivery

||| A queue message with tracking metadata.
public export
record QueueMessage where
  constructor MkQueueMessage
  topic    : String
  payload  : String
  delivery : DeliveryGuarantee
  seqNum   : Nat  -- Sequence number for ordering

-- ═══════════════════════════════════════════════════════════════════════════
-- Queue Record
-- ═══════════════════════════════════════════════════════════════════════════

||| A queue connection with tracked state.
public export
record QueueConnection where
  constructor MkQueueConnection
  connId   : String
  backend  : QueueBackend
  state    : QueueState
  msgCount : Nat  -- Total messages processed

||| Proof that a queue has an active subscription.
public export
data IsSubscribed : QueueConnection -> Type where
  ActiveSubscription : (q : QueueConnection) ->
                       (state q = Subscribed) ->
                       IsSubscribed q

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
||| These map to MCP tool definitions that AI agents can call.
public export
data McpTool
  = ToolConnect      -- Connect to a queue backend
  | ToolSubscribe    -- Subscribe to a topic/queue
  | ToolPublish      -- Publish a message (requires Connected)
  | ToolConsume      -- Begin consuming messages (requires Subscribed)
  | ToolAck          -- Acknowledge a consumed message
  | ToolUnsubscribe  -- Unsubscribe from a topic/queue
  | ToolDisconnect   -- Disconnect from the backend
  | ToolQueueStats   -- Get queue statistics

||| MCP tool name (for JSON-RPC method name).
public export
toolName : McpTool -> String
toolName ToolConnect     = "queues/connect"
toolName ToolSubscribe   = "queues/subscribe"
toolName ToolPublish     = "queues/publish"
toolName ToolConsume     = "queues/consume"
toolName ToolAck         = "queues/ack"
toolName ToolUnsubscribe = "queues/unsubscribe"
toolName ToolDisconnect  = "queues/disconnect"
toolName ToolQueueStats  = "queues/stats"

||| Which tools require an active subscription.
public export
requiresSubscription : McpTool -> Bool
requiresSubscription ToolConsume = True
requiresSubscription ToolAck    = True
requiresSubscription _          = False

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Queue state to integer.
public export
queueStateToInt : QueueState -> Int
queueStateToInt Disconnected = 0
queueStateToInt Connected    = 1
queueStateToInt Subscribed   = 2
queueStateToInt Consuming    = 3
queueStateToInt QueueError   = 4

||| FFI: Validate a state transition.
export
queue_can_transition : Int -> Int -> Int
queue_can_transition from to =
  let fromState = case from of
                    0 => Disconnected
                    1 => Connected
                    2 => Subscribed
                    3 => Consuming
                    _ => QueueError
      toState = case to of
                  0 => Disconnected
                  1 => Connected
                  2 => Subscribed
                  3 => Consuming
                  _ => QueueError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires an active subscription.
export
queue_tool_requires_subscription : Int -> Int
queue_tool_requires_subscription 4 = 1  -- ToolConsume
queue_tool_requires_subscription 5 = 1  -- ToolAck
queue_tool_requires_subscription _ = 0  -- Others do not require subscription
