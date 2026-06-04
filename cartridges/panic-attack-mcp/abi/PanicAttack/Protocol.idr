-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- PanicAttack ABI — security scanner protocol definitions.

module PanicAttack.Protocol

import Data.Nat
import Data.List

||| Scanner operation codes.
public export
data PanicAttackOp
  = Scan
  | GetFindings
  | GetSeverity

||| Severity levels ordered by criticality.
public export
data Severity = Info | Low | Medium | High | Critical

||| A security finding with guaranteed non-empty description.
public export
record Finding where
  constructor MkFinding
  severity    : Severity
  description : String
  {auto prf : NonEmpty (unpack description)}

||| Scan target path.
public export
record ScanTarget where
  constructor MkScanTarget
  path : String

||| Scan result with finding count.
public export
record ScanResult where
  constructor MkScanResult
  findings : List Finding
  totalCount    : Nat
  countPrf : totalCount = length findings

||| Severity has a total ordering — Critical is always >= Info.
public export
severityToNat : Severity -> Nat
severityToNat Info     = 0
severityToNat Low      = 1
severityToNat Medium   = 2
severityToNat High     = 3
severityToNat Critical = 4

||| Proof: Critical severity is strictly greater than Info.
export
criticalGtInfo : LTE 1 (severityToNat Critical)
criticalGtInfo = LTESucc LTEZero
