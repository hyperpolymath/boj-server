-- SPDX-License-Identifier: MPL-2.0
-- Ephapax Cartridge ABI — Proof-compiler query interface

module ABI.Ephapax

%language ElabReflection

-- Proof status enumeration
public export
data ProofStatus : Type where
  ProvenQed : ProofStatus
  ProvenAdmitted : ProofStatus
  ProvenPartial : ProofStatus
  Unproven : ProofStatus
  InvalidProof : ProofStatus

-- Proof metadata record
public export
record ProofMetadata where
  constructor MkProofMetadata
  theoremName : String
  status : ProofStatus
  lines : Nat
  complexity : Nat  -- Estimate (0-100)
  dependencies : List String
  lastModified : String

-- Query result wrapper
public export
record QueryResult where
  constructor MkQueryResult
  success : Bool
  message : String
  data : String

-- Type-checking result
public export
record TypeCheckResult where
  constructor MkTypeCheckResult
  valid : Bool
  inferredType : String
  errors : List String

-- Ephapax cartridge interface
public export
interface Ephapax.Compiler where
  -- Query proof metadata by theorem name
  queryProof : String -> IO ProofMetadata

  -- List all proven theorems in a module
  listProvenTheorems : String -> IO (List ProofMetadata)

  -- Type-check an expression
  typeCheckExpression : String -> IO TypeCheckResult

  -- Analyze proof complexity and dependencies
  analyzeProof : String -> IO QueryResult

  -- Check if cartridge port is loopback-only (compile-time proof)
  IsLoopback : (port : Nat) -> Type
  IsLoopback 5175 = ()

public export
Loopback.proof : IsLoopback 5175
Loopback.proof = ()
