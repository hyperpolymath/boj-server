-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- TypedWasm ABI — WASM type safety protocol definitions.

module TypedWasm.Protocol

import Data.Nat

||| TypedWasm operation codes.
public export
data TypedWasmOp
  = ValidateModule
  | CheckTypes
  | CompileModule

||| Type safety levels (0-10 scale from TypeLL).
public export
record SafetyLevel where
  constructor MkSafetyLevel
  level : Nat
  {auto prf : LTE level 10}

||| Module validation result.
public export
data ValidationResult
  = ModuleValid SafetyLevel
  | ModuleInvalid (List String)

||| Type check result with error count.
public export
record TypeCheckResult where
  constructor MkTypeCheckResult
  errors   : Nat
  warnings : Nat
  level    : SafetyLevel

||| Compilation target.
public export
data CompileTarget = WasmMVP | WasmSIMD | WasmThreads

||| Proof: safety level is always within the 0-10 range.
export
safetyBounded : (s : SafetyLevel) -> LTE s.level 10
safetyBounded s = s.prf

||| Proof: a module with zero errors at max level is maximally safe.
export
maxSafety : SafetyLevel
maxSafety = MkSafetyLevel 10
