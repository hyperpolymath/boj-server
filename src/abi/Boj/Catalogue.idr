-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Boj.Catalogue: The formally verified cartridge registry.
|||
||| This module is the single source of truth for the BoJ 2D capability matrix.
||| Every cartridge occupies a cell in the matrix (ProtocolType x CapabilityDomain)
||| and must pass the IsUnbreakable proof before activation.
|||
||| Key design:
|||   - Cartridges have a lifecycle: Development -> Ready -> Deprecated | Faulty
|||   - Only Ready cartridges can be mounted (enforced by IsUnbreakable proof)
|||   - The matrix is sparse — not every cell needs to be filled
|||   - Hash attestation ties cartridge binaries to their proofs
module Boj.Catalogue

import Data.List
import Boj.Protocol
import Boj.Domain

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Cartridge Lifecycle
-- ═══════════════════════════════════════════════════════════════════════════

||| Operational lifecycle of a cartridge.
||| Development: Under construction, not mountable.
||| Ready: Fully verified, safe to mount.
||| Deprecated: Still works but scheduled for removal.
||| Faulty: Broken or compromised, must not be mounted.
public export
data CartridgeStatus = Development | Ready | Deprecated | Faulty

||| Equality for cartridge status.
public export
Eq CartridgeStatus where
  Development == Development = True
  Ready       == Ready       = True
  Deprecated  == Deprecated  = True
  Faulty      == Faulty      = True
  _           == _           = False

||| C-ABI encoding: status to integer.
public export
statusToInt : CartridgeStatus -> Int
statusToInt Development = 0
statusToInt Ready       = 1
statusToInt Deprecated  = 2
statusToInt Faulty      = 3

||| C-ABI decoding: integer to status.
public export
intToStatus : Int -> Maybe CartridgeStatus
intToStatus 0 = Just Development
intToStatus 1 = Just Ready
intToStatus 2 = Just Deprecated
intToStatus 3 = Just Faulty
intToStatus _ = Nothing

-- ═══════════════════════════════════════════════════════════════════════════
-- Menu Tier (Teranga / Shield / Ayo)
-- ═══════════════════════════════════════════════════════════════════════════

||| Which section of the Teranga menu a cartridge appears in.
||| Teranga: Core cartridges maintained by the project.
||| Shield: Privacy and security cartridges (SDP, oDNS, etc.).
||| Ayo: Community-contributed cartridges (joy of shared work).
public export
data MenuTier = Teranga | Shield | Ayo

||| Equality for menu tiers.
public export
Eq MenuTier where
  Teranga == Teranga = True
  Shield  == Shield  = True
  Ayo     == Ayo     = True
  _       == _       = False

-- ═══════════════════════════════════════════════════════════════════════════
-- Cartridge Definition
-- ═══════════════════════════════════════════════════════════════════════════

||| A cartridge is a formally verified, swappable capability module.
||| It occupies one or more cells in the 2D matrix.
public export
record Cartridge where
  constructor MkCartridge
  name       : String
  version    : String
  status     : CartridgeStatus
  tier       : MenuTier
  domain     : CapabilityDomain
  protocols  : List ProtocolType
  binaryHash : String

-- ═══════════════════════════════════════════════════════════════════════════
-- IsUnbreakable Proof
-- ═══════════════════════════════════════════════════════════════════════════

||| Formal proof that a cartridge is safe for activation.
||| A cartridge is Unbreakable if and only if its status is Ready.
||| This is the core safety gate — the Zig FFI layer checks this
||| before mounting any cartridge.
public export
data IsUnbreakable : Cartridge -> Type where
  VerifiedReady : (c : Cartridge) ->
                  (status c = Ready) ->
                  IsUnbreakable c

-- ═══════════════════════════════════════════════════════════════════════════
-- Matrix Cell
-- ═══════════════════════════════════════════════════════════════════════════

||| A cell in the 2D capability matrix.
||| Represents a specific (protocol, domain) intersection.
public export
record MatrixCell where
  constructor MkCell
  protocol : ProtocolType
  domain   : CapabilityDomain

||| Equality for matrix cells.
public export
Eq MatrixCell where
  (MkCell p1 d1) == (MkCell p2 d2) = p1 == p2 && d1 == d2

||| Which cells a cartridge occupies in the matrix.
||| A cartridge with multiple protocols occupies multiple cells.
public export
cartridgeCells : Cartridge -> List MatrixCell
cartridgeCells c = map (\p => MkCell p (domain c)) (protocols c)

-- ═══════════════════════════════════════════════════════════════════════════
-- Catalogue Queries
-- ═══════════════════════════════════════════════════════════════════════════

||| Retrieve only cartridges that have passed the Unbreakable proof.
public export
getReadyCartridges : List Cartridge -> List Cartridge
getReadyCartridges [] = []
getReadyCartridges (c :: cs) =
  case status c of
    Ready => c :: getReadyCartridges cs
    _     => getReadyCartridges cs

||| Find cartridges by capability domain.
public export
byDomain : CapabilityDomain -> List Cartridge -> List Cartridge
byDomain d [] = []
byDomain d (c :: cs) =
  if domain c == d
    then c :: byDomain d cs
    else byDomain d cs

||| Find cartridges that support a given protocol.
public export
byProtocol : ProtocolType -> List Cartridge -> List Cartridge
byProtocol p [] = []
byProtocol p (c :: cs) =
  if elem p (protocols c)
    then c :: byProtocol p cs
    else byProtocol p cs

||| Find cartridges by menu tier.
public export
byTier : MenuTier -> List Cartridge -> List Cartridge
byTier t [] = []
byTier t (c :: cs) =
  if tier c == t
    then c :: byTier t cs
    else byTier t cs

||| Look up a specific matrix cell: is there a ready cartridge at (protocol, domain)?
public export
lookupCell : ProtocolType -> CapabilityDomain -> List Cartridge -> Maybe Cartridge
lookupCell p d [] = Nothing
lookupCell p d (c :: cs) =
  if domain c == d && elem p (protocols c) && status c == Ready
    then Just c
    else lookupCell p d cs

||| Count ready cartridges (for menu display).
public export
countReady : List Cartridge -> Nat
countReady [] = 0
countReady (c :: cs) =
  case status c of
    Ready => S (countReady cs)
    _     => countReady cs

||| Count total cells occupied in the matrix.
public export
totalCells : List Cartridge -> Nat
totalCells [] = 0
totalCells (c :: cs) = length (protocols c) + totalCells cs
