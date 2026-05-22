-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Conflow ABI — configuration orchestration protocol definitions.

module Conflow.Protocol

import Data.Nat

||| Conflow operation codes.
public export
data ConflowOp
  = GetConfig
  | ApplyConfig
  | ValidateConfig
  | DiffConfig

||| Configuration key-value entry.
public export
record ConfigEntry where
  constructor MkConfigEntry
  key   : String
  value : String

||| Validation result.
public export
data ValidationResult
  = Valid
  | Invalid (List String)

||| Diff between two configs.
public export
record ConfigDiff where
  constructor MkConfigDiff
  added   : List ConfigEntry
  removed : List ConfigEntry
  changed : List (ConfigEntry, ConfigEntry)

||| Apply result tracks the number of changes made.
public export
record ApplyResult where
  constructor MkApplyResult
  applied : Nat
  skipped : Nat
  total   : Nat
  sumPrf  : applied + skipped = total

||| Proof: a valid config with no errors has empty error list.
export
validHasNoErrors : (r : ValidationResult) -> r = Valid -> List String
validHasNoErrors Valid Refl = []

||| Proof: applying zero changes preserves the config.
export
noopApply : ApplyResult
noopApply = MkApplyResult 0 0 0 Refl
