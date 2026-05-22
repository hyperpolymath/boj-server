-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Aerie ABI — environment management protocol definitions.

module Aerie.Protocol

import Data.Nat

||| Aerie operation codes.
public export
data AerieOp
  = ListEnvs
  | CreateEnv
  | DestroyEnv
  | GetStatus

||| Environment lifecycle status.
public export
data EnvStatus = Provisioning | Ready | Destroying | Destroyed | Error

||| Environment with unique name and status.
public export
record Env where
  constructor MkEnv
  name   : String
  status : EnvStatus
  age    : Nat

||| Create request with resource limits.
public export
record CreateReq where
  constructor MkCreateReq
  name     : String
  cpuLimit : Nat
  memMB    : Nat
  {auto prf : IsSucc memMB}

||| Proof: memory limit is always positive by construction.
export
memLimitPositive : (r : CreateReq) -> IsSucc r.memMB
memLimitPositive r = r.prf

||| Proof: a destroyed environment cannot be ready.
export
destroyedNotReady : Not (Destroyed = Ready)
destroyedNotReady Refl impossible
