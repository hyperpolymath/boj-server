-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| AgentMcp.Protocol: Full agentic protocol types for the agent-mcp cartridge.
|||
||| Extends SafeOODA (the OODA loop enforcement) with the comprehensive
||| proven-agentic protocol type system. These types mirror the ABI
||| definitions in proven-servers/protocols/proven-agentic exactly.
|||
||| SafeOODA handles the CONTROL FLOW (Observe→Orient→Decide→Act).
||| Protocol handles the SEMANTICS (tool kinds, plan structure, coordination,
||| safety checks, memory systems).
module AgentMcp.Protocol

import AgentMcp.SafeOODA

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- ToolCall — what kind of tool invocation an agent can make
-- (from proven-agentic Agentic.Types)
-- ═══════════════════════════════════════════════════════════════════════════

||| Classification of tool calls. Used during the Act phase of OODA
||| to categorise what the agent is doing, enabling safety policy enforcement.
public export
data ToolCall : Type where
  Execute     : ToolCall
  Query       : ToolCall
  Transform   : ToolCall
  Communicate : ToolCall
  Delegate    : ToolCall
  Escalate    : ToolCall

public export
Show ToolCall where
  show Execute     = "Execute"
  show Query       = "Query"
  show Transform   = "Transform"
  show Communicate = "Communicate"
  show Delegate    = "Delegate"
  show Escalate    = "Escalate"

||| Whether this tool call has side effects (affects external state).
public export
hasSideEffects : ToolCall -> Bool
hasSideEffects Execute     = True
hasSideEffects Communicate = True
hasSideEffects Delegate    = True
hasSideEffects Escalate    = True
hasSideEffects _           = False

||| Whether this tool call requires a safety pre-check.
public export
requiresSafetyCheck : ToolCall -> Bool
requiresSafetyCheck Execute  = True
requiresSafetyCheck Delegate = True
requiresSafetyCheck Escalate = True
requiresSafetyCheck _        = False

-- ═══════════════════════════════════════════════════════════════════════════
-- PlanStep — node type in an execution plan
-- (from proven-agentic Agentic.Types)
-- ═══════════════════════════════════════════════════════════════════════════

||| A node in the agent's execution plan. Plans are built during the
||| Decide phase and executed during the Act phase.
public export
data PlanStep : Type where
  Action     : PlanStep
  Condition  : PlanStep
  Loop       : PlanStep
  Branch     : PlanStep
  Parallel   : PlanStep
  Checkpoint : PlanStep
  Rollback   : PlanStep

public export
Show PlanStep where
  show Action     = "Action"
  show Condition  = "Condition"
  show Loop       = "Loop"
  show Branch     = "Branch"
  show Parallel   = "Parallel"
  show Checkpoint = "Checkpoint"
  show Rollback   = "Rollback"

-- ═══════════════════════════════════════════════════════════════════════════
-- Coordination — multi-agent coordination strategy
-- (from proven-agentic Agentic.Types)
-- ═══════════════════════════════════════════════════════════════════════════

public export
data Coordination : Type where
  Solo          : Coordination
  Collaborative : Coordination
  Competitive   : Coordination
  Hierarchical  : Coordination
  Swarm         : Coordination
  Consensus     : Coordination

public export
Show Coordination where
  show Solo          = "Solo"
  show Collaborative = "Collaborative"
  show Competitive   = "Competitive"
  show Hierarchical  = "Hierarchical"
  show Swarm         = "Swarm"
  show Consensus     = "Consensus"

-- ═══════════════════════════════════════════════════════════════════════════
-- SafetyCheck — outcome of a safety evaluation before an action
-- (from proven-agentic Agentic.Types)
-- ═══════════════════════════════════════════════════════════════════════════

||| Result of a safety check. Integrates with the OODA loop: an agent
||| in the Decide→Act transition must pass this check first.
public export
data SafetyCheck : Type where
  Approved      : SafetyCheck
  Denied        : SafetyCheck
  Escalated     : SafetyCheck
  Timeout       : SafetyCheck
  Sandboxed     : SafetyCheck
  HumanRequired : SafetyCheck

public export
Show SafetyCheck where
  show Approved      = "Approved"
  show Denied        = "Denied"
  show Escalated     = "Escalated"
  show Timeout       = "Timeout"
  show Sandboxed     = "Sandboxed"
  show HumanRequired = "HumanRequired"

||| Whether the action may proceed (possibly with constraints).
public export
allowsExecution : SafetyCheck -> Bool
allowsExecution Approved = True
allowsExecution Sandboxed = True
allowsExecution _ = False

-- ═══════════════════════════════════════════════════════════════════════════
-- MemoryType — cognitive memory classification
-- (from proven-agentic Agentic.Types)
-- ═══════════════════════════════════════════════════════════════════════════

public export
data MemoryType : Type where
  Working    : MemoryType
  Episodic   : MemoryType
  Semantic   : MemoryType
  Procedural : MemoryType
  Shared     : MemoryType

public export
Show MemoryType where
  show Working    = "Working"
  show Episodic   = "Episodic"
  show Semantic   = "Semantic"
  show Procedural = "Procedural"
  show Shared     = "Shared"

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Encoding — integer encodings for FFI bridge
-- ═══════════════════════════════════════════════════════════════════════════

public export
toolCallToInt : ToolCall -> Int
toolCallToInt Execute     = 0
toolCallToInt Query       = 1
toolCallToInt Transform   = 2
toolCallToInt Communicate = 3
toolCallToInt Delegate    = 4
toolCallToInt Escalate    = 5

public export
intToToolCall : Int -> ToolCall
intToToolCall 0 = Execute
intToToolCall 1 = Query
intToToolCall 2 = Transform
intToToolCall 3 = Communicate
intToToolCall 4 = Delegate
intToToolCall _ = Escalate

public export
safetyCheckToInt : SafetyCheck -> Int
safetyCheckToInt Approved      = 0
safetyCheckToInt Denied        = 1
safetyCheckToInt Escalated     = 2
safetyCheckToInt Timeout       = 3
safetyCheckToInt Sandboxed     = 4
safetyCheckToInt HumanRequired = 5

public export
intToSafetyCheck : Int -> SafetyCheck
intToSafetyCheck 0 = Approved
intToSafetyCheck 1 = Denied
intToSafetyCheck 2 = Escalated
intToSafetyCheck 3 = Timeout
intToSafetyCheck 4 = Sandboxed
intToSafetyCheck _ = HumanRequired

||| FFI: Check if a tool call has side effects.
export
agent_tool_has_side_effects : Int -> Int
agent_tool_has_side_effects t =
  if hasSideEffects (intToToolCall t) then 1 else 0

||| FFI: Check if a tool call requires a safety pre-check.
export
agent_tool_requires_safety : Int -> Int
agent_tool_requires_safety t =
  if requiresSafetyCheck (intToToolCall t) then 1 else 0

||| FFI: Check if a safety check outcome allows execution.
export
agent_safety_allows_exec : Int -> Int
agent_safety_allows_exec s =
  if allowsExecution (intToSafetyCheck s) then 1 else 0
