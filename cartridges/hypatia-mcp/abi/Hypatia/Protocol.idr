-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Hypatia ABI — neurosymbolic CI protocol definitions.

module Hypatia.Protocol

import Data.Nat
import Data.List

||| Hypatia operation codes.
public export
data HypatiaOp
  = ScanRepo
  | TrainModel
  | GetRuleSet
  | GetScore

||| Scan score is bounded 0-100.
public export
record Score where
  constructor MkScore
  value : Nat
  {auto prf : LTE value 100}

||| A rule with unique identifier and description.
public export
record Rule where
  constructor MkRule
  ruleId : String
  name   : String
  weight : Nat

||| Rule set is a non-empty collection.
public export
record RuleSet where
  constructor MkRuleSet
  rules : List Rule
  {auto prf : NonEmpty rules}

||| Training status.
public export
data TrainStatus = Pending | Training | Complete | Failed

||| Proof: a Score with value 0 satisfies the upper bound.
export
zeroIsValidScore : LTE 0 100
zeroIsValidScore = LTEZero

||| Proof: score bound is transitive — if s <= 100 and 100 <= n, then s <= n.
export
scoreBoundTransitive : {s, n : Nat} -> LTE s 100 -> LTE 100 n -> LTE s n
scoreBoundTransitive p q = transitive p q
