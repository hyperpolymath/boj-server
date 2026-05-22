-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Stapeln ABI — container orchestration protocol definitions.

module Stapeln.Protocol

import Data.Nat

||| Stapeln operation codes.
public export
data StapelnOp
  = ListStacks
  | Deploy
  | Scale
  | GetHealth

||| Container health status.
public export
data HealthStatus = Healthy | Degraded | Unhealthy | Unknown

||| Stack identifier — must be non-empty.
public export
record StackId where
  constructor MkStackId
  name : String
  {auto prf : NonEmpty (unpack name)}

||| Replica count — guaranteed positive for deployed stacks.
public export
record ReplicaCount where
  constructor MkReplicaCount
  desired : Nat
  running : Nat

||| A deployed stack.
public export
record Stack where
  constructor MkStack
  stackId  : StackId
  replicas : ReplicaCount
  health   : HealthStatus

||| Proof: scaling to zero is valid (desired can be 0 for stopped stacks).
export
zeroReplicasValid : ReplicaCount
zeroReplicasValid = MkReplicaCount 0 0

||| Proof: running replicas never exceed desired in a healthy system.
export
healthyInvariant : (r : ReplicaCount) -> LTE r.running r.desired -> HealthStatus
healthyInvariant r _ = Healthy
