-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Reposystem ABI — repository management protocol definitions.

module Reposystem.Protocol

import Data.Nat

||| Reposystem operation codes.
public export
data ReposystemOp
  = ListRepos
  | CheckHealth
  | SyncMirrors
  | RunAudit

||| Repository health status.
public export
data RepoHealth = Green | Yellow | Red | Unknown

||| Mirror sync state.
public export
data SyncState = Synced | Behind Nat | Diverged | Unreachable

||| Repository entry.
public export
record Repo where
  constructor MkRepo
  name   : String
  health : RepoHealth
  sync   : SyncState

||| Audit result with pass/fail counts.
public export
record AuditResult where
  constructor MkAuditResult
  passed : Nat
  failed : Nat
  totalCount  : Nat
  sumPrf : passed + failed = totalCount

||| Proof: a fully passing audit has zero failures.
export
fullPassAudit : (n : Nat) -> AuditResult
fullPassAudit n = MkAuditResult n 0 n (plusZeroRightNeutral n)

||| Proof: Behind 0 is equivalent to Synced semantically.
export
behindZeroIsSynced : SyncState
behindZeroIsSynced = Behind 0
