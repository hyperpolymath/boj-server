-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| NesyMcp.SafeReasoning: Formally verified neurosymbolic harmonizer.
|||
||| Cartridge: nesy-mcp
||| Matrix cell: NeSy domain x {MCP, LSP, NeSy, gRPC} protocols
|||
||| Core axiom: Symbolic truth ALWAYS overrides Neural probability.
|||
||| This module defines the formal rules for combining:
|||   - Neural predictions (from Hypatia — pattern recognition, heuristics)
|||   - Symbolic proofs (from Echidna/Proven — formal verification)
|||
||| The harmonization law ensures that a proven result is never
||| overridden by a probabilistic guess, no matter how confident.
module NesyMcp.SafeReasoning

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Verdict Types
-- ═══════════════════════════════════════════════════════════════════════════

||| Neural classification (from Hypatia or similar).
||| These are probabilistic — "probably safe" is NOT "proven safe".
public export
data NeuralVerdict = ProbableSafe | Unsure | ProbableUnsafe

||| Symbolic proof result (from Echidna, Proven, or similar).
||| These are definitive — "proven safe" IS safe.
public export
data SymbolicVerdict = ProvenSafe | NoProof | ProvenUnsafe

||| The harmonized conclusion after combining both verdicts.
public export
data HarmonizedVerdict = CertifiedSafe | RequiresReview | CriticalUnsafe

-- ═══════════════════════════════════════════════════════════════════════════
-- The Harmonization Law
-- ═══════════════════════════════════════════════════════════════════════════

||| Core harmonization: Symbolic truth always overrides Neural probability.
|||
||| The rules:
|||   1. If Symbolic says UNSAFE → CriticalUnsafe (regardless of Neural)
|||   2. If Symbolic says SAFE → CertifiedSafe (regardless of Neural)
|||   3. If Symbolic has NO PROOF → RequiresReview (regardless of Neural)
|||
||| Rule 3 is the key insight: even if Neural says "ProbableSafe",
||| without a proof it's just a guess. We don't certify guesses.
public export
harmonize : NeuralVerdict -> SymbolicVerdict -> HarmonizedVerdict
harmonize _              ProvenUnsafe = CriticalUnsafe
harmonize _              ProvenSafe   = CertifiedSafe
harmonize ProbableUnsafe NoProof      = CriticalUnsafe   -- Neural alarm + no proof = escalate
harmonize Unsure         NoProof      = RequiresReview
harmonize ProbableSafe   NoProof      = RequiresReview    -- Even if neural thinks safe, no proof = review

-- ═══════════════════════════════════════════════════════════════════════════
-- Confidence Levels
-- ═══════════════════════════════════════════════════════════════════════════

||| How confident we are in a harmonized verdict.
public export
data ConfidenceLevel = Absolute | High | Low

||| Derive confidence from the input verdicts.
public export
confidence : NeuralVerdict -> SymbolicVerdict -> ConfidenceLevel
confidence _ ProvenSafe   = Absolute   -- Proof is absolute
confidence _ ProvenUnsafe = Absolute   -- Proof is absolute
confidence ProbableSafe   NoProof = Low
confidence Unsure         NoProof = Low
confidence ProbableUnsafe NoProof = High -- Neural alarm is worth paying attention to

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Encoding/Decoding
-- ═══════════════════════════════════════════════════════════════════════════

||| Neural verdict to integer.
public export
neuralToInt : NeuralVerdict -> Int
neuralToInt ProbableSafe   = 1
neuralToInt Unsure         = 2
neuralToInt ProbableUnsafe = 3

||| Integer to neural verdict (safe default: Unsure).
public export
intToNeural : Int -> NeuralVerdict
intToNeural 1 = ProbableSafe
intToNeural 3 = ProbableUnsafe
intToNeural _ = Unsure

||| Symbolic verdict to integer.
public export
symbolicToInt : SymbolicVerdict -> Int
symbolicToInt ProvenSafe   = 1
symbolicToInt NoProof      = 2
symbolicToInt ProvenUnsafe = 3

||| Integer to symbolic verdict (safe default: NoProof).
public export
intToSymbolic : Int -> SymbolicVerdict
intToSymbolic 1 = ProvenSafe
intToSymbolic 3 = ProvenUnsafe
intToSymbolic _ = NoProof

||| Harmonized verdict to integer.
public export
harmonizedToInt : HarmonizedVerdict -> Int
harmonizedToInt CertifiedSafe  = 1
harmonizedToInt RequiresReview = 2
harmonizedToInt CriticalUnsafe = 3

||| Confidence level to integer.
public export
confidenceToInt : ConfidenceLevel -> Int
confidenceToInt Absolute = 3
confidenceToInt High     = 2
confidenceToInt Low      = 1

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| FFI: Harmonize neural and symbolic verdicts.
||| Takes integer-encoded verdicts, returns integer-encoded result.
export
nesy_harmonize : Int -> Int -> Int
nesy_harmonize n s =
  harmonizedToInt (harmonize (intToNeural n) (intToSymbolic s))

||| FFI: Get confidence level for a harmonization.
export
nesy_confidence : Int -> Int -> Int
nesy_confidence n s =
  confidenceToInt (confidence (intToNeural n) (intToSymbolic s))
