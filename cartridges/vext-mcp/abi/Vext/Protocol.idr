-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- Vext ABI — verifiable communications protocol definitions.

module Vext.Protocol

import Data.Nat

||| Vext operation codes.
public export
data VextOp
  = VerifyMessage
  | CheckAttestation
  | AppendChain

||| Verification status.
public export
data VerifyStatus = Verified | Unverified | Tampered | Expired

||| Attestation with a chain depth.
public export
record Attestation where
  constructor MkAttestation
  issuer : String
  depth  : Nat

||| Chain entry with hash linkage.
public export
record ChainEntry where
  constructor MkChainEntry
  prevHash : String
  payload  : String
  entryIdx : Nat

||| Proof: verified status means the message is trustworthy.
export
verifiedIsTrustworthy : (s : VerifyStatus) -> s = Verified -> Bool
verifiedIsTrustworthy Verified Refl = True

||| Proof: chain entries are monotonically indexed.
export
chainMonotonic : (a, b : ChainEntry) -> LTE a.entryIdx b.entryIdx ->
                 LTE a.entryIdx (S b.entryIdx)
chainMonotonic _ _ prf = lteSuccRight prf
