-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Kategoria ABI — categorization protocol definitions.

module Kategoria.Protocol

import Data.Nat

||| Kategoria operation codes.
public export
data KategoriaOp
  = Classify
  | GetRoutes
  | GetLevels
  | EvalChallenge

||| Classification confidence (0-100).
public export
record Confidence where
  constructor MkConfidence
  value : Nat
  {auto prf : LTE value 100}

||| A classification result with label and confidence.
public export
record Classification where
  constructor MkClassification
  label      : String
  confidence : Confidence
  route      : List String

||| Challenge level for evaluation.
public export
record ChallengeLevel where
  constructor MkChallengeLevel
  level      : Nat
  difficulty : Nat
  {auto prf : LTE level 12}

||| Route depth — guaranteed non-negative.
public export
routeDepth : Classification -> Nat
routeDepth c = length c.route

||| Proof: confidence is always bounded.
export
confidenceBounded : (c : Confidence) -> LTE c.value 100
confidenceBounded c = c.prf

||| Proof: challenge level is within clade taxonomy bounds (12 codes).
export
challengeInBounds : (cl : ChallengeLevel) -> LTE cl.level 12
challengeInBounds cl = cl.prf
