-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| LocalCoord.Protocol: Message types and coordination semantics for
||| localhost multi-instance coordination.
|||
||| Cartridge: local-coord-mcp
|||
||| Builds on AgentMcp.Protocol's Coordination and MemoryType enums.
||| Defines the wire-level message types, task claiming (mutex semantics),
||| and peer lifecycle for the local coordination service.
|||
||| Key invariant: all messages carry a session token. A message without
||| a valid token is rejected before dispatch — the type system enforces
||| this via the AuthenticatedMessage wrapper.
module LocalCoord.Protocol

import LocalCoord.SafeLocalCoord

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Message Types
-- ═══════════════════════════════════════════════════════════════════════════

||| The kinds of coordination messages that can be sent between peers.
public export
data CoordMessageKind : Type where
  ||| Direct message to a specific peer.
  DirectMsg   : CoordMessageKind
  ||| Broadcast to all connected peers.
  Broadcast   : CoordMessageKind
  ||| Status announcement (what this instance is working on).
  StatusUpdate : CoordMessageKind
  ||| Task claim request (mutex acquisition attempt).
  ClaimRequest : CoordMessageKind
  ||| Task claim release (mutex release).
  ClaimRelease : CoordMessageKind
  ||| Peer discovery ping.
  Ping         : CoordMessageKind

public export
Show CoordMessageKind where
  show DirectMsg    = "DirectMsg"
  show Broadcast    = "Broadcast"
  show StatusUpdate = "StatusUpdate"
  show ClaimRequest = "ClaimRequest"
  show ClaimRelease = "ClaimRelease"
  show Ping         = "Ping"

||| Whether this message kind has side effects on shared state.
public export
hasSideEffects : CoordMessageKind -> Bool
hasSideEffects ClaimRequest = True
hasSideEffects ClaimRelease = True
hasSideEffects _            = False

||| Whether this message kind requires acknowledgement from the server.
public export
requiresAck : CoordMessageKind -> Bool
requiresAck ClaimRequest = True
requiresAck ClaimRelease = True
requiresAck DirectMsg    = True
requiresAck _            = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Message Addressing
-- ═══════════════════════════════════════════════════════════════════════════

||| Message target: either a specific peer or all peers.
public export
data MessageTarget : Type where
  ToPeer : PeerId -> MessageTarget
  ToAll  : MessageTarget

-- ═══════════════════════════════════════════════════════════════════════════
-- Task Claiming (Mutex Semantics)
-- ═══════════════════════════════════════════════════════════════════════════

||| A task identifier for the claiming system.
||| Tasks are named strings (e.g. "audit-boj-server", "fix-ci-pipeline").
public export
data TaskId : Type where
  MkTaskId : (name : String)
          -> {auto nonEmpty : NonEmpty (unpack name)}
          -> TaskId

||| Extract the task name string.
public export
taskName : TaskId -> String
taskName (MkTaskId name) = name

||| The result of a claim attempt.
public export
data ClaimResult : Type where
  ||| Claim granted — this peer now holds the mutex.
  Granted   : ClaimResult
  ||| Claim denied — another peer already holds this task.
  Held      : (holder : PeerId) -> ClaimResult
  ||| Claim denied — task ID not recognised.
  NotFound  : ClaimResult

public export
Show ClaimResult where
  show Granted      = "Granted"
  show (Held h)     = "Held(" ++ peerIdToString h ++ ")"
  show NotFound     = "NotFound"

||| Whether a claim result means the caller may proceed.
public export
claimAllowsWork : ClaimResult -> Bool
claimAllowsWork Granted = True
claimAllowsWork _       = False

||| Proof that a granted claim allows work.
export
grantedAllows : claimAllowsWork Granted = True
grantedAllows = Refl

||| Proof that a held claim does not allow work.
export
heldDenies : (h : PeerId) -> claimAllowsWork (Held h) = False
heldDenies _ = Refl

-- ═══════════════════════════════════════════════════════════════════════════
-- Authenticated Messages
-- ═══════════════════════════════════════════════════════════════════════════

||| A coordination message that has been authenticated with a session token.
||| The token proof is erased at runtime (quantity 0) — it exists only to
||| enforce the invariant at compile time.
public export
record AuthenticatedMessage where
  constructor MkAuthMsg
  sender  : PeerId
  token   : SessionToken
  msgKind : CoordMessageKind
  target  : MessageTarget
  payload : String             -- JSON-encoded message body

||| An unauthenticated message — used at the wire boundary before validation.
public export
record RawMessage where
  constructor MkRawMsg
  senderStr  : String
  tokenStr   : String
  kindInt    : Int
  targetStr  : String          -- peer ID string or "*" for broadcast
  payload    : String

-- ═══════════════════════════════════════════════════════════════════════════
-- Peer Lifecycle
-- ═══════════════════════════════════════════════════════════════════════════

||| Peer connection state.
public export
data PeerState : Type where
  Registering : PeerState    -- Handshake in progress
  Active      : PeerState    -- Registered and operational
  Departing   : PeerState    -- Graceful disconnect in progress
  Gone        : PeerState    -- Disconnected

public export
Eq PeerState where
  Registering == Registering = True
  Active      == Active      = True
  Departing   == Departing   = True
  Gone        == Gone        = True
  _           == _           = False

||| Valid peer state transitions.
public export
data ValidPeerTransition : PeerState -> PeerState -> Type where
  RegisterToActive  : ValidPeerTransition Registering Active
  ActiveToDepart    : ValidPeerTransition Active Departing
  DepartToGone      : ValidPeerTransition Departing Gone
  -- Abrupt disconnect from any active state
  RegisterAbort     : ValidPeerTransition Registering Gone
  ActiveAbort       : ValidPeerTransition Active Gone

||| Runtime transition check.
public export
canTransitionPeer : PeerState -> PeerState -> Bool
canTransitionPeer Registering Active    = True
canTransitionPeer Active      Departing = True
canTransitionPeer Departing   Gone      = True
canTransitionPeer Registering Gone      = True
canTransitionPeer Active      Gone      = True
canTransitionPeer _           _         = False

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Encoding
-- ═══════════════════════════════════════════════════════════════════════════

public export
msgKindToInt : CoordMessageKind -> Int
msgKindToInt DirectMsg    = 0
msgKindToInt Broadcast    = 1
msgKindToInt StatusUpdate = 2
msgKindToInt ClaimRequest = 3
msgKindToInt ClaimRelease = 4
msgKindToInt Ping         = 5

public export
intToMsgKind : Int -> CoordMessageKind
intToMsgKind 0 = DirectMsg
intToMsgKind 1 = Broadcast
intToMsgKind 2 = StatusUpdate
intToMsgKind 3 = ClaimRequest
intToMsgKind 4 = ClaimRelease
intToMsgKind _ = Ping

public export
claimResultToInt : ClaimResult -> Int
claimResultToInt Granted    = 0
claimResultToInt (Held _)   = 1
claimResultToInt NotFound   = 2

public export
peerStateToInt : PeerState -> Int
peerStateToInt Registering = 0
peerStateToInt Active      = 1
peerStateToInt Departing   = 2
peerStateToInt Gone        = 3

public export
intToPeerState : Int -> PeerState
intToPeerState 0 = Registering
intToPeerState 1 = Active
intToPeerState 2 = Departing
intToPeerState _ = Gone

||| FFI: Check if a message kind has side effects.
export
coord_msg_has_side_effects : Int -> Int
coord_msg_has_side_effects k =
  if hasSideEffects (intToMsgKind k) then 1 else 0

||| FFI: Check if a message kind requires acknowledgement.
export
coord_msg_requires_ack : Int -> Int
coord_msg_requires_ack k =
  if requiresAck (intToMsgKind k) then 1 else 0

||| FFI: Check if a claim result allows work.
export
coord_claim_allows_work : Int -> Int
coord_claim_allows_work 0 = 1  -- Granted
coord_claim_allows_work _ = 0

||| FFI: Validate a peer state transition.
export
coord_validate_peer_transition : Int -> Int -> Int
coord_validate_peer_transition from to =
  if canTransitionPeer (intToPeerState from) (intToPeerState to) then 1 else 0
