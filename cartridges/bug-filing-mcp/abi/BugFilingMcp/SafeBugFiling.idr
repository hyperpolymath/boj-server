-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| BugFilingMcp.SafeBugFiling: Formally verified bug-filing pipeline states.
|||
||| Cartridge: bug-filing-mcp (wraps the feedback-o-tron engine)
||| Matrix cell: Development domain x {MCP, REST} protocols
|||
||| This module defines the interactive filing pipeline as a state machine
||| that prevents:
|||   - Submitting a report that was rejected by the usefulness gate
|||   - Submitting template answers that were never validated
|||   - Skipping research when a duplicate check is required
|||
||| Doctrine encoded (feedback-o-tron design intent):
|||   - the gate is usefulness, not tone: Salvaged is a live state, not an end
|||   - zero-signal hostility dead-ends in Rejected (no path to Submitted)
|||   - open questions loop Synthesized -> Synthesized until validation
|||
||| State machine:
|||   Draft -> Researched -> Synthesized -> Validated -> Submitted
|||            (Synthesized may be Salvaged first; Rejected is terminal)
module BugFilingMcp.SafeBugFiling

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Filing Pipeline State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Pipeline lifecycle states for one piece of feedback.
public export
data FilingState
  = Draft        -- raw feedback exists, nothing checked
  | Researched   -- duplicates + template questions fetched
  | Salvaged     -- hostile wrapping stripped; actionable core kept
  | Synthesized  -- template hydrated; open questions may remain
  | Validated    -- answers passed the form-schema boundary
  | Submitted    -- dispatched to the forge(s)
  | Rejected     -- zero-signal hostility: terminal, never filed

||| Equality for filing states.
public export
Eq FilingState where
  Draft       == Draft       = True
  Researched  == Researched  = True
  Salvaged    == Salvaged    = True
  Synthesized == Synthesized = True
  Validated   == Validated   = True
  Submitted   == Submitted   = True
  Rejected    == Rejected    = True
  _           == _           = False

||| Valid state transitions (enforced at the type level).
||| Critically there is NO constructor targeting Submitted except from
||| Validated, and NO constructor leaving Rejected.
public export
data ValidTransition : FilingState -> FilingState -> Type where
  Research    : ValidTransition Draft Researched
  SalvageCore : ValidTransition Researched Salvaged
  Synthesize  : ValidTransition Researched Synthesized
  Resynth     : ValidTransition Synthesized Synthesized  -- open-questions loop
  FromSalvage : ValidTransition Salvaged Synthesized
  Validate    : ValidTransition Synthesized Validated
  Submit      : ValidTransition Validated Submitted
  RejectR     : ValidTransition Researched Rejected
  RejectD     : ValidTransition Draft Rejected

||| Runtime transition validator (mirrors ValidTransition).
public export
canTransition : FilingState -> FilingState -> Bool
canTransition Draft       Researched  = True
canTransition Researched  Salvaged    = True
canTransition Researched  Synthesized = True
canTransition Synthesized Synthesized = True
canTransition Salvaged    Synthesized = True
canTransition Synthesized Validated   = True
canTransition Validated   Submitted   = True
canTransition Researched  Rejected    = True
canTransition Draft       Rejected    = True
canTransition _           _           = False

||| Rejected is terminal: no transition out of it is ever valid.
export
rejectedIsTerminal : (s : FilingState) -> ValidTransition Rejected s -> Void
rejectedIsTerminal _ Research    impossible
rejectedIsTerminal _ SalvageCore impossible
rejectedIsTerminal _ Synthesize  impossible
rejectedIsTerminal _ Resynth     impossible
rejectedIsTerminal _ FromSalvage impossible
rejectedIsTerminal _ Validate    impossible
rejectedIsTerminal _ Submit      impossible
rejectedIsTerminal _ RejectR     impossible
rejectedIsTerminal _ RejectD     impossible

||| Submission only ever follows validation: the sole transition into
||| Submitted starts at Validated.
export
submitRequiresValidation : (s : FilingState) -> ValidTransition s Submitted -> s = Validated
submitRequiresValidation Validated Submit = Refl

-- ═══════════════════════════════════════════════════════════════════════════
-- MCP Tool Definitions
-- ═══════════════════════════════════════════════════════════════════════════

||| MCP tools exposed by this cartridge.
public export
data McpTool
  = ToolResearch    -- research_feedback
  | ToolSynthesize  -- synthesize_feedback
  | ToolSubmit      -- submit_feedback

||| MCP tool name (must match cartridge.json).
public export
toolName : McpTool -> String
toolName ToolResearch   = "research_feedback"
toolName ToolSynthesize = "synthesize_feedback"
toolName ToolSubmit     = "submit_feedback"

||| The pipeline state each tool drives toward.
public export
toolTarget : McpTool -> FilingState
toolTarget ToolResearch   = Researched
toolTarget ToolSynthesize = Synthesized
toolTarget ToolSubmit     = Submitted

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Filing state to integer for the C ABI.
public export
filingStateToInt : FilingState -> Int
filingStateToInt Draft       = 0
filingStateToInt Researched  = 1
filingStateToInt Salvaged    = 2
filingStateToInt Synthesized = 3
filingStateToInt Validated   = 4
filingStateToInt Submitted   = 5
filingStateToInt Rejected    = 6

||| Integer to filing state (unknown collapses to Rejected: fail closed).
public export
intToFilingState : Int -> FilingState
intToFilingState 0 = Draft
intToFilingState 1 = Researched
intToFilingState 2 = Salvaged
intToFilingState 3 = Synthesized
intToFilingState 4 = Validated
intToFilingState 5 = Submitted
intToFilingState _ = Rejected

||| FFI: Validate a state transition.
export
bf_can_transition : Int -> Int -> Int
bf_can_transition from to =
  if canTransition (intToFilingState from) (intToFilingState to) then 1 else 0
