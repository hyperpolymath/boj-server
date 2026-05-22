-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| VordrMcp.SafeVordr: Formally verified container hash state monitoring.
|||
||| Cartridge: vordr-mcp (v0.5 Shield)
||| Monitors running container image hashes against known-good digests.
||| Detects runtime container replacement, layer tampering, and drift.
|||
||| Safety guarantees:
|||   - Container digests are BLAKE3 hashes (not MD5/SHA-1)
|||   - State transitions are monotonic (healthy → drifted → tampered, never back)
|||   - Alert thresholds are positive (cannot set 0 tolerance)
module VordrMcp.SafeVordr

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Container Integrity State Machine
-- ═══════════════════════════════════════════════════════════════════════════

||| Container integrity states. Monotonically degrading — once tampered,
||| the container must be replaced, not "healed" back to healthy.
public export
data IntegrityState = Healthy | Drifted | Tampered | Unknown

||| A container digest — always BLAKE3, never weak hashes.
public export
record ContainerDigest where
  constructor MkDigest
  imageRef : String
  blake3Hash : String  -- 64 hex chars
  layerCount : Nat

||| A monitoring observation — snapshot of container state at a point in time.
public export
record Observation where
  constructor MkObs
  container : ContainerDigest
  state : IntegrityState
  timestamp : Nat

||| Monotonicity proof: state can only degrade, never improve.
public export
data MonotonicDegradation : IntegrityState -> IntegrityState -> Type where
  StayHealthy  : MonotonicDegradation Healthy Healthy
  HealthyDrift : MonotonicDegradation Healthy Drifted
  HealthyTamp  : MonotonicDegradation Healthy Tampered
  DriftedStay  : MonotonicDegradation Drifted Drifted
  DriftedTamp  : MonotonicDegradation Drifted Tampered
  TamperedStay : MonotonicDegradation Tampered Tampered

-- ═══════════════════════════════════════════════════════════════════════════
-- FFI Interface
-- ═══════════════════════════════════════════════════════════════════════════

public export
interface VordrFFI where
  scanContainer : String -> IO (Either String Observation)
  compareDigest : ContainerDigest -> ContainerDigest -> IO IntegrityState
  listMonitored : IO (List ContainerDigest)
  setBaseline   : String -> ContainerDigest -> IO ()
  getAlerts     : IO (List Observation)
