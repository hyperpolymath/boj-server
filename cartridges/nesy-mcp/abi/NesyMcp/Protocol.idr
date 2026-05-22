-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| NesyMcp.Protocol: Full neurosymbolic protocol types for the nesy-mcp cartridge.
|||
||| Extends SafeReasoning (the harmonization law) with the comprehensive
||| proven-nesy protocol type system. These types mirror the ABI definitions
||| in proven-servers/protocols/proven-nesy exactly.
|||
||| SafeReasoning handles the WHAT (harmonize verdicts).
||| Protocol handles the HOW (reasoning modes, backends, drift, merge strategies).
module NesyMcp.Protocol

import NesyMcp.SafeReasoning

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- ReasoningMode — which paradigm to use for a query
-- (from proven-nesy NeSy.Types)
-- ═══════════════════════════════════════════════════════════════════════════

||| The reasoning paradigm to apply. Extends the basic Neural/Symbolic
||| binary from SafeReasoning into a richer taxonomy of hybrid modes.
public export
data ReasoningMode : Type where
  Symbolic    : ReasoningMode
  Neural      : ReasoningMode
  SymToNeural : ReasoningMode
  NeuralToSym : ReasoningMode
  Ensemble    : ReasoningMode
  Cascade     : ReasoningMode

public export
Show ReasoningMode where
  show Symbolic    = "Symbolic"
  show Neural      = "Neural"
  show SymToNeural = "SymToNeural"
  show NeuralToSym = "NeuralToSym"
  show Ensemble    = "Ensemble"
  show Cascade     = "Cascade"

||| Whether this mode engages the symbolic layer.
public export
usesSymbolic : ReasoningMode -> Bool
usesSymbolic Neural = False
usesSymbolic _      = True

||| Whether this mode engages the neural layer.
public export
usesNeural : ReasoningMode -> Bool
usesNeural Symbolic = False
usesNeural _        = True

-- ═══════════════════════════════════════════════════════════════════════════
-- ProofStatus — lifecycle of a proof obligation
-- (from proven-nesy NeSy.Types)
-- ═══════════════════════════════════════════════════════════════════════════

public export
data ProofStatus : Type where
  Pending    : ProofStatus
  Attempting : ProofStatus
  Proved     : ProofStatus
  Failed     : ProofStatus
  Assumed    : ProofStatus
  Vacuous    : ProofStatus

public export
Show ProofStatus where
  show Pending    = "Pending"
  show Attempting = "Attempting"
  show Proved     = "Proved"
  show Failed     = "Failed"
  show Assumed    = "Assumed"
  show Vacuous    = "Vacuous"

-- ═══════════════════════════════════════════════════════════════════════════
-- NeuralBackend — which inference engine
-- (from proven-nesy NeSy.Types)
-- ═══════════════════════════════════════════════════════════════════════════

public export
data NeuralBackend : Type where
  LocalModel   : NeuralBackend
  Claude       : NeuralBackend
  Gemini       : NeuralBackend
  Mistral      : NeuralBackend
  GPT          : NeuralBackend
  CustomNeural : NeuralBackend

public export
Show NeuralBackend where
  show LocalModel   = "LocalModel"
  show Claude       = "Claude"
  show Gemini       = "Gemini"
  show Mistral      = "Mistral"
  show GPT          = "GPT"
  show CustomNeural = "CustomNeural"

-- ═══════════════════════════════════════════════════════════════════════════
-- DriftKind — how symbolic and neural results diverge
-- (from proven-nesy NeSy.Types)
-- ═══════════════════════════════════════════════════════════════════════════

public export
data DriftKind : Type where
  NoDrift           : DriftKind
  SemanticDrift     : DriftKind
  ConfidenceDrift   : DriftKind
  FactualDrift      : DriftKind
  TemporalDrift     : DriftKind
  CatastrophicDrift : DriftKind

public export
Show DriftKind where
  show NoDrift           = "NoDrift"
  show SemanticDrift     = "SemanticDrift"
  show ConfidenceDrift   = "ConfidenceDrift"
  show FactualDrift      = "FactualDrift"
  show TemporalDrift     = "TemporalDrift"
  show CatastrophicDrift = "CatastrophicDrift"

-- ═══════════════════════════════════════════════════════════════════════════
-- MergeStrategy — how to combine results
-- (from proven-nesy NeSy.Integration)
-- ═══════════════════════════════════════════════════════════════════════════

public export
data MergeStrategy : Type where
  SymbolicPrimacy       : MergeStrategy
  NeuralPrimacy         : MergeStrategy
  ConfidenceWeighted    : MergeStrategy
  Consensus             : MergeStrategy
  DualReturn            : MergeStrategy
  ConstrainedGeneration : MergeStrategy

public export
Show MergeStrategy where
  show SymbolicPrimacy       = "SymbolicPrimacy"
  show NeuralPrimacy         = "NeuralPrimacy"
  show ConfidenceWeighted    = "ConfidenceWeighted"
  show Consensus             = "Consensus"
  show DualReturn            = "DualReturn"
  show ConstrainedGeneration = "ConstrainedGeneration"

-- ═══════════════════════════════════════════════════════════════════════════
-- DriftAction — what to do when drift is detected
-- (from proven-nesy NeSy.Integration)
-- ═══════════════════════════════════════════════════════════════════════════

public export
data DriftAction : Type where
  LogAndAccept  : DriftAction
  FlagForReview : DriftAction
  RejectNeural  : DriftAction
  RetryNeural   : DriftAction
  Escalate      : DriftAction
  Halt          : DriftAction

public export
Show DriftAction where
  show LogAndAccept  = "LogAndAccept"
  show FlagForReview = "FlagForReview"
  show RejectNeural  = "RejectNeural"
  show RetryNeural   = "RetryNeural"
  show Escalate      = "Escalate"
  show Halt          = "Halt"

-- ═══════════════════════════════════════════════════════════════════════════
-- GroundingStatus — is the neural output grounded in symbolic facts?
-- (from proven-nesy NeSy.Integration)
-- ═══════════════════════════════════════════════════════════════════════════

public export
data GroundingStatus : Type where
  FullyGrounded     : GroundingStatus
  PartiallyGrounded : GroundingStatus
  Ungrounded        : GroundingStatus
  GroundingPending  : GroundingStatus
  GroundingFailed   : GroundingStatus

public export
Show GroundingStatus where
  show FullyGrounded     = "FullyGrounded"
  show PartiallyGrounded = "PartiallyGrounded"
  show Ungrounded        = "Ungrounded"
  show GroundingPending  = "GroundingPending"
  show GroundingFailed   = "GroundingFailed"

-- ═══════════════════════════════════════════════════════════════════════════
-- Drift Recommendation — pure function connecting DriftKind to DriftAction
-- ═══════════════════════════════════════════════════════════════════════════

||| Recommend the default action for a given drift severity.
||| This is the policy-level complement to SafeReasoning's harmonization law.
public export
recommendDriftAction : DriftKind -> DriftAction
recommendDriftAction NoDrift           = LogAndAccept
recommendDriftAction SemanticDrift     = LogAndAccept
recommendDriftAction ConfidenceDrift   = FlagForReview
recommendDriftAction FactualDrift      = RejectNeural
recommendDriftAction TemporalDrift     = RetryNeural
recommendDriftAction CatastrophicDrift = Halt

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Encoding — integer encodings for FFI bridge
-- ═══════════════════════════════════════════════════════════════════════════

public export
reasoningModeToInt : ReasoningMode -> Int
reasoningModeToInt Symbolic    = 0
reasoningModeToInt Neural      = 1
reasoningModeToInt SymToNeural = 2
reasoningModeToInt NeuralToSym = 3
reasoningModeToInt Ensemble    = 4
reasoningModeToInt Cascade     = 5

public export
driftKindToInt : DriftKind -> Int
driftKindToInt NoDrift           = 0
driftKindToInt SemanticDrift     = 1
driftKindToInt ConfidenceDrift   = 2
driftKindToInt FactualDrift      = 3
driftKindToInt TemporalDrift     = 4
driftKindToInt CatastrophicDrift = 5

public export
intToDriftKind : Int -> DriftKind
intToDriftKind 0 = NoDrift
intToDriftKind 1 = SemanticDrift
intToDriftKind 2 = ConfidenceDrift
intToDriftKind 3 = FactualDrift
intToDriftKind 4 = TemporalDrift
intToDriftKind _ = CatastrophicDrift

public export
driftActionToInt : DriftAction -> Int
driftActionToInt LogAndAccept  = 0
driftActionToInt FlagForReview = 1
driftActionToInt RejectNeural  = 2
driftActionToInt RetryNeural   = 3
driftActionToInt Escalate      = 4
driftActionToInt Halt          = 5

||| FFI: Recommend a drift action given a drift kind (integer-encoded).
export
nesy_recommend_drift_action : Int -> Int
nesy_recommend_drift_action d =
  driftActionToInt (recommendDriftAction (intToDriftKind d))
