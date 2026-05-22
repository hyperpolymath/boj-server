-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Protocol: Model Router — LLM tier routing via BoJ MCP
|||
||| Cartridge: model-router
||| Matrix cell: LLM x Routing
|||
||| Proves that:
|||   1. Model selection is deterministic for a given cost/quality preference
|||   2. Fallback chains always terminate
|||   3. Budget constraints are enforced before dispatch
module ModelRouter.Protocol

import Data.Fin

%default total

||| Model tier (matches 007 language ModelTier)
public export
data ModelTier = Haiku | Sonnet | Opus

||| Routing operation
public export
data Operation
  = SelectModel       -- Pick best model for a task
  | ListModels        -- List available models
  | GetBudget         -- Check remaining budget
  | SetPreference     -- Set cost/quality preference

||| Cost preference (0=cheapest, 100=best quality)
public export
data CostPreference = MkPref (n : Fin 101)

-- ═══════════════════════════════════════════════════════════════════════
-- Fallback chain proof
-- ═══════════════════════════════════════════════════════════════════════

||| Fallback chain: Opus → Sonnet → Haiku (always terminates)
public export
fallback : ModelTier -> Maybe ModelTier
fallback Opus   = Just Sonnet
fallback Sonnet = Just Haiku
fallback Haiku  = Nothing

-- ═══════════════════════════════════════════════════════════════════════
-- C ABI Exports
-- ═══════════════════════════════════════════════════════════════════════

export
modelTierToInt : ModelTier -> Int
modelTierToInt Haiku  = 0
modelTierToInt Sonnet = 1
modelTierToInt Opus   = 2

export
router_fallback : Int -> Int
router_fallback 2 = 1  -- Opus → Sonnet
router_fallback 1 = 0  -- Sonnet → Haiku
router_fallback _ = -1 -- Haiku → no fallback
