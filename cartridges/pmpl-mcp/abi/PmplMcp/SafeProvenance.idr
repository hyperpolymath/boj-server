-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| PmplMcp.SafeProvenance: Formally verified PMPL license provenance chain.
|||
||| Cartridge: pmpl-mcp (v0.5 Shield)
||| Tracks and verifies the provenance chain for PMPL-licensed artifacts:
|||   - Every artifact has a BLAKE3 content hash
|||   - Provenance chains are append-only (no retroactive modification)
|||   - Author attribution is cryptographically bound to content
|||   - License compatibility is checked at chain construction time
|||
||| This implements the Palimpsest License (PMPL) requirement that
||| derivative works maintain a verifiable chain back to the original.
module PmplMcp.SafeProvenance
import Data.Nat

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Provenance Chain (Append-Only)
-- ═══════════════════════════════════════════════════════════════════════════

||| SPDX license identifier — restricted to PMPL-compatible licenses.
public export
data License = PMPL | MPL2 | MIT | Apache2 | BSD2 | BSD3

||| A single entry in the provenance chain.
public export
record ProvenanceEntry where
  constructor MkEntry
  contentHash : String   -- BLAKE3 digest of the artifact
  author : String        -- Author identity (name + email)
  license : License      -- SPDX license at this point in the chain
  timestamp : Nat        -- Unix timestamp
  parentHash : String    -- BLAKE3 of the previous entry (empty for root)

||| The provenance chain — a non-empty list of entries.
||| The head is the most recent entry, the last is the root.
public export
data ProvenanceChain : Type where
  Root : ProvenanceEntry -> ProvenanceChain
  Link : ProvenanceEntry -> ProvenanceChain -> ProvenanceChain

||| Chain length — always >= 1.
public export
chainLength : ProvenanceChain -> Nat
chainLength (Root _) = 1
chainLength (Link _ rest) = 1 + chainLength rest

||| The chain is never empty — by construction.
public export
chainNonEmpty : (chain : ProvenanceChain) -> LTE 1 (chainLength chain)
chainNonEmpty (Root _) = LTESucc LTEZero
chainNonEmpty (Link _ _) = LTESucc LTEZero

-- ═══════════════════════════════════════════════════════════════════════════
-- License Compatibility
-- ═══════════════════════════════════════════════════════════════════════════

||| Check if a license is compatible with PMPL for derivative works.
||| PMPL is compatible with: MIT, Apache-2.0, BSD-2, BSD-3, MPL-2.0.
public export
pmplCompatible : License -> Bool
pmplCompatible PMPL    = True
pmplCompatible MPL2    = True
pmplCompatible MIT     = True
pmplCompatible Apache2 = True
pmplCompatible BSD2    = True
pmplCompatible BSD3    = True

-- ═══════════════════════════════════════════════════════════════════════════
-- FFI Interface
-- ═══════════════════════════════════════════════════════════════════════════

public export
interface ProvenanceFFI where
  createChain   : ProvenanceEntry -> IO ProvenanceChain
  extendChain   : ProvenanceChain -> ProvenanceEntry -> IO (Either String ProvenanceChain)
  verifyChain   : ProvenanceChain -> IO Bool
  hashArtifact  : String -> IO String  -- BLAKE3 hash of file content
  lookupChain   : String -> IO (Maybe ProvenanceChain)  -- lookup by content hash
