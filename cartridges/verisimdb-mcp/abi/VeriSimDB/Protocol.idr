-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- VeriSimDB ABI — provenance database protocol definitions.

module VeriSimDB.Protocol

import Data.Nat
import Data.Vect

||| VeriSimDB operation codes.
public export
data VeriSimDBOp
  = StoreOctad
  | GetOctad
  | DetectDrift
  | QueryAudit

||| An octad is exactly 8 provenance fields.
public export
Octad : Type
Octad = Vect 8 String

||| Drift detection result.
public export
data DriftStatus = NoDrift | DriftDetected Nat

||| Audit query with timestamp bounds.
public export
record AuditQuery where
  constructor MkAuditQuery
  fromTs : Nat
  toTs   : Nat
  {auto prf : LTE fromTs toTs}

||| Stored octad with a unique hash.
public export
record StoredOctad where
  constructor MkStoredOctad
  hash  : String
  octad : Octad

||| Proof: an Octad always has exactly 8 elements.
export
octadLength : (o : Octad) -> length o = 8
octadLength o = lengthCorrect o

||| Proof: audit query time range is non-negative.
export
auditRangeValid : (q : AuditQuery) -> LTE q.fromTs q.toTs
auditRangeValid q = q.prf
