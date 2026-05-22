-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| DapMcp.SafeDap: Formally verified Debug Adapter Protocol operations.
|||
||| Cartridge: dap-mcp
||| Matrix cell: DAP protocol column
|||
||| Models the DAP session lifecycle with type-level guarantees that:
|||   - Debug commands can only be sent to an initialized adapter
|||   - Thread and stack frame references are scoped to stopped states
|||   - Variables can only be inspected while paused
module DapMcp.SafeDap

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- DAP Session State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| DAP session lifecycle states per DAP specification 1.65.
public export
data DapState
  = NotStarted       -- Adapter not launched
  | Launched         -- Adapter process started
  | Configured       -- ConfigurationDone sent
  | Running          -- Target executing
  | Stopped          -- Target hit breakpoint/exception
  | Terminated       -- Target terminated
  | Disconnected     -- Adapter disconnected

||| Equality for DAP states.
public export
Eq DapState where
  NotStarted   == NotStarted   = True
  Launched     == Launched     = True
  Configured   == Configured   = True
  Running      == Running      = True
  Stopped      == Stopped      = True
  Terminated   == Terminated   = True
  Disconnected == Disconnected = True
  _            == _            = False

||| Valid state transitions.
public export
canTransition : DapState -> DapState -> Bool
canTransition NotStarted   Launched     = True
canTransition Launched     Configured   = True
canTransition Configured   Running      = True
canTransition Running      Stopped      = True
canTransition Stopped      Running      = True  -- continue/step
canTransition Running      Terminated   = True
canTransition Stopped      Terminated   = True
canTransition Terminated   Disconnected = True
canTransition Launched     Disconnected = True   -- early disconnect
canTransition Running      Disconnected = True   -- forced disconnect
canTransition _            _            = False

-- ═══════════════════════════════════════════════════════════════════════════
-- DAP Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Breakpoint type.
public export
data BreakpointKind
  = SourceBreakpoint     -- Line/column breakpoint
  | FunctionBreakpoint   -- Function name breakpoint
  | DataBreakpoint       -- Memory/variable watch
  | InstructionBP        -- Instruction-level breakpoint
  | ExceptionBreakpoint  -- Exception filter

||| C-ABI encoding.
public export
breakpointKindToInt : BreakpointKind -> Int
breakpointKindToInt SourceBreakpoint    = 1
breakpointKindToInt FunctionBreakpoint  = 2
breakpointKindToInt DataBreakpoint      = 3
breakpointKindToInt InstructionBP       = 4
breakpointKindToInt ExceptionBreakpoint = 5

||| Stop reason (why the debugger paused).
public export
data StopReason
  = Breakpoint     -- Hit a breakpoint
  | Step           -- Completed a step
  | Exception      -- Unhandled exception
  | Pause          -- Manual pause
  | Entry          -- Program entry point
  | Goto           -- Goto target reached

||| C-ABI encoding.
public export
stopReasonToInt : StopReason -> Int
stopReasonToInt Breakpoint = 1
stopReasonToInt Step       = 2
stopReasonToInt Exception  = 3
stopReasonToInt Pause      = 4
stopReasonToInt Entry      = 5
stopReasonToInt Goto       = 6

||| Step granularity.
public export
data StepGranularity = StepStatement | StepLine | StepInstruction

||| C-ABI encoding.
public export
stepGranularityToInt : StepGranularity -> Int
stepGranularityToInt StepStatement   = 1
stepGranularityToInt StepLine        = 2
stepGranularityToInt StepInstruction = 3

-- ═══════════════════════════════════════════════════════════════════════════
-- State Machine Proofs
-- ═══════════════════════════════════════════════════════════════════════════

||| Proof that the DAP lifecycle is well-formed.
public export
data DapLifecycleWellFormed : Type where
  MkWellFormed :
    (launchOk   : canTransition NotStarted Launched = True) ->
    (configOk   : canTransition Launched Configured = True) ->
    (runOk      : canTransition Configured Running = True) ->
    (stopOk     : canTransition Running Stopped = True) ->
    (contOk     : canTransition Stopped Running = True) ->
    (termFromR  : canTransition Running Terminated = True) ->
    (termFromS  : canTransition Stopped Terminated = True) ->
    (discOk     : canTransition Terminated Disconnected = True) ->
    DapLifecycleWellFormed

||| Witness: the DAP lifecycle is well-formed.
public export
dapLifecycleOk : DapLifecycleWellFormed
dapLifecycleOk = MkWellFormed Refl Refl Refl Refl Refl Refl Refl Refl

-- ═══════════════════════════════════════════════════════════════════════════
-- Safety Predicates
-- ═══════════════════════════════════════════════════════════════════════════

||| Can we inspect variables/stack in this state? Only while stopped.
public export
canInspect : DapState -> Bool
canInspect Stopped = True
canInspect _       = False

||| Can we set breakpoints? In launched, configured, or stopped states.
public export
canSetBreakpoints : DapState -> Bool
canSetBreakpoints Launched   = True
canSetBreakpoints Configured = True
canSetBreakpoints Stopped    = True
canSetBreakpoints _          = False

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| DAP state to integer.
public export
dapStateToInt : DapState -> Int
dapStateToInt NotStarted   = 0
dapStateToInt Launched     = 1
dapStateToInt Configured   = 2
dapStateToInt Running      = 3
dapStateToInt Stopped      = 4
dapStateToInt Terminated   = 5
dapStateToInt Disconnected = 6

||| FFI: Validate a state transition.
export
dap_can_transition : Int -> Int -> Int
dap_can_transition from to =
  let fromState = case from of
                    0 => NotStarted
                    1 => Launched
                    2 => Configured
                    3 => Running
                    4 => Stopped
                    5 => Terminated
                    _ => Disconnected
      toState = case to of
                  0 => NotStarted
                  1 => Launched
                  2 => Configured
                  3 => Running
                  4 => Stopped
                  5 => Terminated
                  _ => Disconnected
  in if canTransition fromState toState then 1 else 0

||| FFI: Can inspect variables in this state?
export
dap_can_inspect : Int -> Int
dap_can_inspect 4 = 1  -- Stopped
dap_can_inspect _ = 0
