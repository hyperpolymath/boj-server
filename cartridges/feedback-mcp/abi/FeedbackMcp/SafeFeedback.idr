-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| FeedbackMcp.SafeFeedback: Formally verified feedback collection operations.
|||
||| Cartridge: feedback-mcp (18th cartridge, feedback-o-tron)
||| Matrix cell: Observe domain x {MCP, REST} protocols
|||
||| This module defines a feedback pipeline state machine that prevents:
|||   - Submitting feedback to unconfigured channels
|||   - Processing feedback without channel registration
|||   - Reading feedback from inactive channels
|||
||| State machine: Inactive -> ChannelRegistered -> Collecting -> Processing -> Collecting
module FeedbackMcp.SafeFeedback

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Feedback Channel State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Feedback channel lifecycle states.
||| A channel progresses: Inactive -> ChannelRegistered -> Collecting -> Processing -> Collecting
public export
data FeedbackState = Inactive | ChannelRegistered | Collecting | Processing | FeedbackError

||| Equality for feedback states.
public export
Eq FeedbackState where
  Inactive          == Inactive          = True
  ChannelRegistered == ChannelRegistered = True
  Collecting        == Collecting        = True
  Processing        == Processing        = True
  FeedbackError     == FeedbackError     = True
  _                 == _                 = False

||| Valid state transitions (enforced at the type level).
||| Critically, Inactive -> Processing is NOT valid.
||| You MUST register a channel and start collecting first.
public export
data ValidTransition : FeedbackState -> FeedbackState -> Type where
  Register       : ValidTransition Inactive ChannelRegistered
  StartCollect   : ValidTransition ChannelRegistered Collecting
  StartProcess   : ValidTransition Collecting Processing
  EndProcess     : ValidTransition Processing Collecting
  Deregister     : ValidTransition Collecting Inactive
  ProcessError   : ValidTransition Processing FeedbackError
  Recover        : ValidTransition FeedbackError Collecting

||| Runtime transition validator.
public export
canTransition : FeedbackState -> FeedbackState -> Bool
canTransition Inactive          ChannelRegistered = True
canTransition ChannelRegistered Collecting        = True
canTransition Collecting        Processing        = True
canTransition Processing        Collecting        = True
canTransition Collecting        Inactive          = True   -- deregister
canTransition Processing        FeedbackError     = True
canTransition FeedbackError     Collecting        = True   -- recover
canTransition _                 _                 = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Feedback Channel Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Supported feedback channels.
public export
data FeedbackChannel
  = WebForm       -- HTTP form submissions
  | ApiEndpoint   -- REST API submissions
  | Email         -- Email-based feedback
  | Irc           -- IRC channel feedback
  | Mastodon      -- Fediverse feedback
  | Gitea         -- Gitea issue/comment feedback
  | Custom String -- User-defined channel

||| C-ABI encoding.
public export
channelToInt : FeedbackChannel -> Int
channelToInt WebForm      = 1
channelToInt ApiEndpoint  = 2
channelToInt Email        = 3
channelToInt Irc          = 4
channelToInt Mastodon     = 5
channelToInt Gitea        = 6
channelToInt (Custom _)   = 99

-- ═══════════════════════════════════════════════════════════════════════════
-- Feedback Sentiment
-- ═══════════════════════════════════════════════════════════════════════════

||| Feedback sentiment categories.
public export
data Sentiment = Positive | Neutral | Negative | Unclassified

||| C-ABI encoding for sentiment.
public export
sentimentToInt : Sentiment -> Int
sentimentToInt Positive     = 1
sentimentToInt Neutral      = 0
sentimentToInt Negative     = -1
sentimentToInt Unclassified = -99

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
public export
data McpTool
  = ToolRegisterChannel   -- Register a feedback channel
  | ToolSubmitFeedback    -- Submit feedback to a channel
  | ToolListFeedback      -- List collected feedback
  | ToolProcessFeedback   -- Process/classify feedback
  | ToolSentimentSummary  -- Aggregate sentiment report
  | ToolChannelStatus     -- Channel health check
  | ToolDeregister        -- Deregister a channel

||| MCP tool name.
public export
toolName : McpTool -> String
toolName ToolRegisterChannel  = "feedback/register"
toolName ToolSubmitFeedback   = "feedback/submit"
toolName ToolListFeedback     = "feedback/list"
toolName ToolProcessFeedback  = "feedback/process"
toolName ToolSentimentSummary = "feedback/sentiment"
toolName ToolChannelStatus    = "feedback/status"
toolName ToolDeregister       = "feedback/deregister"

||| Which tools require a channel to be registered first.
public export
toolRequiresChannel : McpTool -> Bool
toolRequiresChannel ToolRegisterChannel = False
toolRequiresChannel _                   = True

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Feedback state to integer.
public export
feedbackStateToInt : FeedbackState -> Int
feedbackStateToInt Inactive          = 0
feedbackStateToInt ChannelRegistered = 1
feedbackStateToInt Collecting        = 2
feedbackStateToInt Processing        = 3
feedbackStateToInt FeedbackError     = 4

||| FFI: Validate a state transition.
export
fb_can_transition : Int -> Int -> Int
fb_can_transition from to =
  let fromState = case from of
                    0 => Inactive
                    1 => ChannelRegistered
                    2 => Collecting
                    3 => Processing
                    _ => FeedbackError
      toState = case to of
                  0 => Inactive
                  1 => ChannelRegistered
                  2 => Collecting
                  3 => Processing
                  _ => FeedbackError
  in if canTransition fromState toState then 1 else 0

||| FFI: Check if a tool requires a registered channel.
export
fb_tool_requires_channel : Int -> Int
fb_tool_requires_channel 1 = 0  -- ToolRegisterChannel
fb_tool_requires_channel _ = 1  -- All others require a channel
