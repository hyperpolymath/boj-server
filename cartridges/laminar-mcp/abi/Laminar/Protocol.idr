-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Laminar ABI — pipeline orchestration protocol definitions.

module Laminar.Protocol

import Data.Nat

||| Laminar operation codes.
public export
data LaminarOp
  = CreatePipeline
  | RunStage
  | GetStatus
  | CancelPipeline

||| Pipeline execution status.
public export
data PipelineStatus = Pending | Running | Succeeded | Failed | Cancelled

||| Stage within a pipeline.
public export
record Stage where
  constructor MkStage
  name   : String
  index  : Nat
  status : PipelineStatus

||| Pipeline with ordered stages.
public export
record Pipeline where
  constructor MkPipeline
  pipelineId : Nat
  stages     : List Stage
  current    : Nat

||| Proof: a pipeline's current stage index is bounded by total stages.
export
currentStageBounded : (p : Pipeline) -> LTE p.current (length p.stages) ->
                      LTE p.current (S (length p.stages))
currentStageBounded _ prf = lteSuccRight prf

||| Proof: a cancelled pipeline has a valid terminal status.
export
cancelledIsTerminal : (s : PipelineStatus) -> s = Cancelled -> Bool
cancelledIsTerminal Cancelled Refl = True
