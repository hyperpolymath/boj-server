-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| AgentMcp.SafeOODA: Formally verified autonomous agent loop.
|||
||| Cartridge: agent-mcp
||| Matrix cell: (future Agentic domain) x {MCP, Agentic, gRPC} protocols
|||
||| Implements Boyd's OODA loop (Observe → Orient → Decide → Act) as a
||| dependent type state machine. The key guarantee: an agent CANNOT
||| jump from Observe to Act — it must pass through Orient and Decide.
|||
||| This prevents "shoot first, think later" agent behaviour where an
||| AI acts on raw observations without analysis or planning.
|||
||| The state machine is cyclic: Act → Observe starts a new loop.
||| Emergency stops are modelled as a separate Halted state.
module AgentMcp.SafeOODA

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- OODA States
-- ═══════════════════════════════════════════════════════════════════════════

||| The OODA loop states plus a Halted state for emergency stops.
public export
data AgentState
  = Observe    -- Gathering data from environment
  | Orient     -- Analysing data, building situational awareness
  | Decide     -- Choosing a course of action
  | Act        -- Executing the chosen action
  | Halted     -- Emergency stop (any state can transition here)

||| Equality for agent states.
public export
Eq AgentState where
  Observe == Observe = True
  Orient  == Orient  = True
  Decide  == Decide  = True
  Act     == Act     = True
  Halted  == Halted  = True
  _       == _       = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Valid Transitions (the proof)
-- ═══════════════════════════════════════════════════════════════════════════

||| Proof that a state transition is valid.
||| This is the core safety guarantee — these are the ONLY legal transitions.
||| An agent cannot construct a proof for Observe → Act, so the type system
||| prevents it at compile time.
public export
data ValidOODA : AgentState -> AgentState -> Type where
  ObsToOri  : ValidOODA Observe Orient    -- Must analyse before deciding
  OriToDec  : ValidOODA Orient  Decide    -- Must decide before acting
  DecToAct  : ValidOODA Decide  Act       -- Execute the decision
  ActToObs  : ValidOODA Act     Observe   -- New loop starts with observation
  -- Emergency halt from any active state
  ObsHalt   : ValidOODA Observe Halted
  OriHalt   : ValidOODA Orient  Halted
  DecHalt   : ValidOODA Decide  Halted
  ActHalt   : ValidOODA Act     Halted
  -- Resume from halt (back to Observe — start fresh)
  HaltToObs : ValidOODA Halted  Observe

||| Runtime transition validator.
||| Returns True only for transitions that have a corresponding proof above.
public export
canTransition : AgentState -> AgentState -> Bool
canTransition Observe Orient  = True
canTransition Orient  Decide  = True
canTransition Decide  Act     = True
canTransition Act     Observe = True
canTransition Observe Halted  = True
canTransition Orient  Halted  = True
canTransition Decide  Halted  = True
canTransition Act     Halted  = True
canTransition Halted  Observe = True
canTransition _       _       = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Agent Session
-- ═══════════════════════════════════════════════════════════════════════════

||| An agent session tracks the current state and loop count.
public export
record AgentSession where
  constructor MkSession
  agentId   : String
  state     : AgentState
  loopCount : Nat          -- How many complete OODA loops so far
  halted    : Bool         -- Has this session ever been halted?

||| Create a new session (always starts at Observe).
public export
newSession : String -> AgentSession
newSession aid = MkSession aid Observe 0 False

||| Attempt a state transition. Returns the new session if valid.
public export
transition : AgentSession -> AgentState -> Maybe AgentSession
transition session newState =
  if canTransition (state session) newState
    then let loops = if state session == Act && newState == Observe
                       then S (loopCount session)
                       else loopCount session
             wasHalted = halted session || newState == Halted
         in Just (MkSession (agentId session) newState loops wasHalted)
    else Nothing

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| State to integer.
public export
stateToInt : AgentState -> Int
stateToInt Observe = 1
stateToInt Orient  = 2
stateToInt Decide  = 3
stateToInt Act     = 4
stateToInt Halted  = 5

||| Integer to state (safe default: Halted).
public export
intToState : Int -> AgentState
intToState 1 = Observe
intToState 2 = Orient
intToState 3 = Decide
intToState 4 = Act
intToState _ = Halted

||| FFI: Validate a state transition.
||| Returns 1 if valid, 0 if invalid.
export
agent_validate_ooda : Int -> Int -> Int
agent_validate_ooda from to =
  if canTransition (intToState from) (intToState to) then 1 else 0

||| FFI: Get the next valid state in the standard OODA sequence.
||| Returns the integer encoding of the next state, or 5 (Halted) if stuck.
export
agent_next_state : Int -> Int
agent_next_state 1 = 2  -- Observe -> Orient
agent_next_state 2 = 3  -- Orient  -> Decide
agent_next_state 3 = 4  -- Decide  -> Act
agent_next_state 4 = 1  -- Act     -> Observe (new loop)
agent_next_state _ = 5  -- Halted or unknown -> Halted
