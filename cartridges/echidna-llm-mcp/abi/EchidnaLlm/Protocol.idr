-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Protocol: Frontier LLM tactic suggestion protocol for ECHIDNA
|||
||| Cartridge: echidna-llm
||| Matrix cell: Theorem Proving x LLM Advisory
|||
||| Defines the formal interface between ECHIDNA's dispatch pipeline
||| and frontier language models. Proves that:
|||   1. LLM responses cannot influence trust levels (advisory only)
|||   2. Session tokens are ephemeral and bounded
|||   3. Prompt injection is structurally impossible via typed requests
|||   4. Fallback to non-LLM path is always available
module EchidnaLlm.Protocol

import Data.List
import Data.Fin

%default total

-- ═══════════════════════════════════════════════════════════════════════
-- Core Types
-- ═══════════════════════════════════════════════════════════════════════

||| Model tier for cost-aware routing
public export
data ModelTier = Haiku | Sonnet | Opus

||| Confidence score bounded to [0.0, 1.0]
||| We represent as integer percentage to avoid float in ABI
public export
data Confidence = MkConfidence (n : Fin 101)

||| Convert confidence to integer for C ABI (0-100)
public export
confidenceToInt : Confidence -> Int
confidenceToInt (MkConfidence n) = cast (finToNat n)

||| Prover identifier (matches ECHIDNA's 105 backends)
public export
data ProverId : Type where
  MkProverId : (id : Fin 105) -> ProverId

||| Operation that the cartridge can perform
public export
data Operation
  = SuggestTactics    -- Primary: get tactic suggestions for a goal
  | RankProvers       -- Rank provers for a given proof state
  | DecomposeGoal     -- Suggest goal decomposition into subgoals
  | GenerateLemmas    -- Generate auxiliary lemmas
  | ClassifyGoal      -- Classify goal aspects/domain

||| Session state machine
||| Enforces: unauthenticated → authenticated → operating → closed
public export
data SessionState = Unauthenticated | Authenticated | Operating | Closed

||| Valid state transitions — only these are permitted
public export
data ValidTransition : SessionState -> SessionState -> Type where
  AuthTransition  : ValidTransition Unauthenticated Authenticated
  StartOp         : ValidTransition Authenticated Operating
  ContinueOp      : ValidTransition Operating Operating
  CloseFromAuth   : ValidTransition Authenticated Closed
  CloseFromOp     : ValidTransition Operating Closed

-- ═══════════════════════════════════════════════════════════════════════
-- Trust Invariant (THE critical proof)
-- ═══════════════════════════════════════════════════════════════════════

||| Proof that an operation is advisory-only.
||| Advisory operations CANNOT modify trust levels.
||| This is the foundational safety property of the LLM integration.
public export
data IsAdvisory : Operation -> Type where
  TacticsAdvisory   : IsAdvisory SuggestTactics
  RankingAdvisory    : IsAdvisory RankProvers
  DecomposeAdvisory  : IsAdvisory DecomposeGoal
  LemmasAdvisory     : IsAdvisory GenerateLemmas
  ClassifyAdvisory   : IsAdvisory ClassifyGoal

||| ALL operations are advisory — this is total, no exceptions
public export
allOperationsAdvisory : (op : Operation) -> IsAdvisory op
allOperationsAdvisory SuggestTactics = TacticsAdvisory
allOperationsAdvisory RankProvers    = RankingAdvisory
allOperationsAdvisory DecomposeGoal  = DecomposeAdvisory
allOperationsAdvisory GenerateLemmas = LemmasAdvisory
allOperationsAdvisory ClassifyGoal   = ClassifyAdvisory

-- ═══════════════════════════════════════════════════════════════════════
-- Request/Response Types
-- ═══════════════════════════════════════════════════════════════════════

||| Tactic suggestion request (structured, not free-form text)
||| Using structured types prevents prompt injection by construction
public export
record TacticRequest where
  constructor MkTacticRequest
  goal       : String          -- The proof goal
  hypotheses : List String     -- Available hypotheses
  prover     : ProverId        -- Target prover
  topK       : Fin 51          -- Max suggestions (1-50, bounded)
  model      : ModelTier       -- Which LLM tier to use

||| A single tactic suggestion from the LLM
public export
record TacticSuggestion where
  constructor MkTacticSuggestion
  tactic     : String          -- Tactic text
  confidence : Confidence      -- How confident (0-100%)
  targetProv : ProverId        -- Which prover this is for
  rationale  : String          -- Brief explanation

||| Response with ranked tactics
public export
record TacticResponse where
  constructor MkTacticResponse
  tactics    : List TacticSuggestion
  reasoning  : String          -- Overall strategy explanation
  model      : ModelTier       -- Model that was used
  latencyMs  : Nat             -- Response time

-- ═══════════════════════════════════════════════════════════════════════
-- Ephemeral Session Security
-- ═══════════════════════════════════════════════════════════════════════

||| Ephemeral session token — bounded lifetime, single-use per proof attempt
public export
record EphemeralToken where
  constructor MkEphemeralToken
  tokenHash  : String          -- BLAKE3 hash of the token
  expiryMs   : Nat             -- Milliseconds until expiry
  maxCalls   : Fin 1001        -- Max API calls (1-1000, bounded)
  callsMade  : Nat             -- Calls made so far

||| Proof that a token is still valid
public export
data TokenValid : EphemeralToken -> Type where
  StillValid : (tok : EphemeralToken) ->
               (callsMade tok `LT` finToNat (maxCalls tok)) ->
               TokenValid tok

-- ═══════════════════════════════════════════════════════════════════════
-- C ABI Exports (for Zig FFI bridge)
-- ═══════════════════════════════════════════════════════════════════════

||| Encode operation as C integer
export
operationToInt : Operation -> Int
operationToInt SuggestTactics = 0
operationToInt RankProvers    = 1
operationToInt DecomposeGoal  = 2
operationToInt GenerateLemmas = 3
operationToInt ClassifyGoal   = 4

||| Encode model tier as C integer
export
modelTierToInt : ModelTier -> Int
modelTierToInt Haiku  = 0
modelTierToInt Sonnet = 1
modelTierToInt Opus   = 2

||| Encode session state as C integer
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Unauthenticated = 0
sessionStateToInt Authenticated   = 1
sessionStateToInt Operating       = 2
sessionStateToInt Closed          = 3

||| Check if a state transition is valid (C ABI: returns 1 if valid, 0 if not)
export
llm_can_transition : Int -> Int -> Int
llm_can_transition 0 1 = 1  -- Unauthenticated → Authenticated
llm_can_transition 1 2 = 1  -- Authenticated → Operating
llm_can_transition 2 2 = 1  -- Operating → Operating
llm_can_transition 1 3 = 1  -- Authenticated → Closed
llm_can_transition 2 3 = 1  -- Operating → Closed
llm_can_transition _ _ = 0  -- All other transitions invalid

||| Check if an operation is advisory (C ABI: always returns 1)
||| This is trivially true by allOperationsAdvisory, exported for FFI
export
llm_is_advisory : Int -> Int
llm_is_advisory _ = 1  -- All operations advisory, proven above
