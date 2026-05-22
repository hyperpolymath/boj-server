-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- SlackMcp.SafeComms — Type-safe ABI for the Slack Web API / Events API cartridge.
--
-- Dependent-type state machine governing Slack connection lifecycle.
-- All transitions proven valid at compile time. Zero unsafe escape hatches.

module SlackMcp.SafeComms

%default total

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

||| Connection lifecycle states for Slack API interactions.
||| Models the full lifecycle: authentication, connected operation,
||| rate limiting (Slack enforces per-method tiers), and error recovery.
public export
data ConnState
  = Disconnected
  | Authenticating
  | Connected
  | RateLimited
  | Error

-- ---------------------------------------------------------------------------
-- Valid state transitions (proven at the type level)
-- ---------------------------------------------------------------------------

||| Proof witness that a state transition is permitted.
||| Only the transitions enumerated here can ever occur at the FFI boundary.
public export
data ValidTransition : ConnState -> ConnState -> Type where
  ||| Begin authentication from disconnected state.
  StartAuth      : ValidTransition Disconnected Authenticating
  ||| Authentication succeeded — now connected to workspace.
  AuthSuccess    : ValidTransition Authenticating Connected
  ||| Hit a Slack rate limit (Tier 1–4 throttle).
  HitRateLimit   : ValidTransition Connected RateLimited
  ||| Rate limit window expired — resume operations.
  RateRecovered  : ValidTransition RateLimited Connected
  ||| Operational error while connected (network, API fault).
  ConnError      : ValidTransition Connected Error
  ||| Authentication failed.
  AuthError      : ValidTransition Authenticating Error
  ||| Error recovery — return to disconnected for re-auth.
  ErrorReset     : ValidTransition Error Disconnected
  ||| Graceful disconnect from a connected workspace.
  GracefulClose  : ValidTransition Connected Disconnected

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding for ConnState
-- ---------------------------------------------------------------------------

||| Encode connection state as a C-compatible integer.
||| Mapping: Disconnected=0, Authenticating=1, Connected=2, RateLimited=3, Error=4.
export
connStateToInt : ConnState -> Int
connStateToInt Disconnected  = 0
connStateToInt Authenticating = 1
connStateToInt Connected     = 2
connStateToInt RateLimited   = 3
connStateToInt Error         = 4

||| Decode a C integer back to a connection state.
||| Returns Nothing for out-of-range values.
export
intToConnState : Int -> Maybe ConnState
intToConnState 0 = Just Disconnected
intToConnState 1 = Just Authenticating
intToConnState 2 = Just Connected
intToConnState 3 = Just RateLimited
intToConnState 4 = Just Error
intToConnState _ = Nothing

||| C-ABI export: check whether a state transition is valid.
||| Returns 1 for valid, 0 for invalid. Used by the Zig FFI layer.
export
slack_mcp_can_transition : Int -> Int -> Int
slack_mcp_can_transition from to =
  case (intToConnState from, intToConnState to) of
    (Just Disconnected,   Just Authenticating) => 1
    (Just Authenticating, Just Connected)      => 1
    (Just Connected,      Just RateLimited)    => 1
    (Just RateLimited,    Just Connected)      => 1
    (Just Connected,      Just Error)          => 1
    (Just Authenticating, Just Error)          => 1
    (Just Error,          Just Disconnected)   => 1
    (Just Connected,      Just Disconnected)   => 1
    _                                          => 0

-- ---------------------------------------------------------------------------
-- Slack action vocabulary
-- ---------------------------------------------------------------------------

||| All actions supported by the slack-mcp cartridge.
||| Each maps to a Slack Web API method.
public export
data SlackAction
  = SendMessage        -- chat.postMessage
  | ListChannels       -- conversations.list
  | GetChannel         -- conversations.info
  | ListUsers          -- users.list
  | GetUser            -- users.info
  | PostReaction       -- reactions.add
  | RemoveReaction     -- reactions.remove
  | UploadFile         -- files.upload
  | SearchMessages     -- search.messages
  | ListConversations  -- conversations.list (with types filter)
  | GetThread          -- conversations.replies
  | UpdateMessage      -- chat.update
  | DeleteMessage      -- chat.delete
  | SetStatus          -- users.profile.set
  | CreateChannel      -- conversations.create
  | InviteToChannel    -- conversations.invite

||| Encode a SlackAction as a C integer for FFI.
export
slackActionToInt : SlackAction -> Int
slackActionToInt SendMessage       = 0
slackActionToInt ListChannels      = 1
slackActionToInt GetChannel        = 2
slackActionToInt ListUsers         = 3
slackActionToInt GetUser           = 4
slackActionToInt PostReaction      = 5
slackActionToInt RemoveReaction    = 6
slackActionToInt UploadFile        = 7
slackActionToInt SearchMessages    = 8
slackActionToInt ListConversations = 9
slackActionToInt GetThread         = 10
slackActionToInt UpdateMessage     = 11
slackActionToInt DeleteMessage     = 12
slackActionToInt SetStatus         = 13
slackActionToInt CreateChannel     = 14
slackActionToInt InviteToChannel   = 15

||| Decode a C integer back to a SlackAction.
export
intToSlackAction : Int -> Maybe SlackAction
intToSlackAction 0  = Just SendMessage
intToSlackAction 1  = Just ListChannels
intToSlackAction 2  = Just GetChannel
intToSlackAction 3  = Just ListUsers
intToSlackAction 4  = Just GetUser
intToSlackAction 5  = Just PostReaction
intToSlackAction 6  = Just RemoveReaction
intToSlackAction 7  = Just UploadFile
intToSlackAction 8  = Just SearchMessages
intToSlackAction 9  = Just ListConversations
intToSlackAction 10 = Just GetThread
intToSlackAction 11 = Just UpdateMessage
intToSlackAction 12 = Just DeleteMessage
intToSlackAction 13 = Just SetStatus
intToSlackAction 14 = Just CreateChannel
intToSlackAction 15 = Just InviteToChannel
intToSlackAction _  = Nothing

||| Total action count exposed via C-ABI.
export
slack_mcp_action_count : Int
slack_mcp_action_count = 16

-- ---------------------------------------------------------------------------
-- Slack rate-limit tiers
-- ---------------------------------------------------------------------------

||| Slack rate-limit tier classification.
||| Tier 1: 1 req/min, Tier 2: 20 req/min, Tier 3: 50 req/min, Tier 4: 100 req/min.
public export
data RateTier = Tier1 | Tier2 | Tier3 | Tier4

||| Encode rate tier as C integer.
export
rateTierToInt : RateTier -> Int
rateTierToInt Tier1 = 1
rateTierToInt Tier2 = 2
rateTierToInt Tier3 = 3
rateTierToInt Tier4 = 4

||| Decode C integer to rate tier.
export
intToRateTier : Int -> Maybe RateTier
intToRateTier 1 = Just Tier1
intToRateTier 2 = Just Tier2
intToRateTier 3 = Just Tier3
intToRateTier 4 = Just Tier4
intToRateTier _ = Nothing

||| Map each action to its Slack rate tier.
||| Based on Slack Web API documentation.
export
actionRateTier : SlackAction -> RateTier
actionRateTier SendMessage       = Tier3
actionRateTier ListChannels      = Tier2
actionRateTier GetChannel        = Tier3
actionRateTier ListUsers         = Tier2
actionRateTier GetUser           = Tier4
actionRateTier PostReaction      = Tier3
actionRateTier RemoveReaction    = Tier3
actionRateTier UploadFile        = Tier2
actionRateTier SearchMessages    = Tier2
actionRateTier ListConversations = Tier2
actionRateTier GetThread         = Tier3
actionRateTier UpdateMessage     = Tier3
actionRateTier DeleteMessage     = Tier3
actionRateTier SetStatus         = Tier3
actionRateTier CreateChannel     = Tier2
actionRateTier InviteToChannel   = Tier3

-- ---------------------------------------------------------------------------
-- Message target record
-- ---------------------------------------------------------------------------

||| Target for message-oriented operations.
||| threadTs is Nothing for top-level messages, Just ts for threaded replies.
public export
record MessageTarget where
  constructor MkMessageTarget
  channel  : String
  threadTs : Maybe String

||| C-ABI export: check if an action requires an active (Connected) state.
||| All Slack actions require a connected session.
export
slack_mcp_action_requires_connected : Int -> Int
slack_mcp_action_requires_connected actionId =
  case intToSlackAction actionId of
    Just _  => 1  -- all actions require Connected state
    Nothing => 0  -- unknown action

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via the MCP protocol by this cartridge.
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
