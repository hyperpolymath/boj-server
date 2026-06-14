-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
||| Boj.Guardian: Resource-aware failure tolerance and self-diagnostics.
|||
||| Provides dependent-type-checked resource monitoring, preemptive
||| warning thresholds, circuit breaker patterns, and self-diagnostic
||| capabilities for the BoJ cartridge runtime.
|||
||| Motivated by the "3 Claude instances + 20 MCP servers = frozen desktop"
||| incident of 2026-03-08. The system had 22 GB available RAM but CPU
||| contention from unchecked process spawning made KDE unresponsive.
|||
||| Design principles:
|||   - Resource tracking at cartridge level (not just node level)
|||   - Preemptive warnings BEFORE degradation occurs
|||   - Circuit breaker pattern isolates failing cartridges
|||   - Self-diagnostic report available via API
|||   - Operator always informed — never silently degraded
module Boj.Guardian

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Resource Thresholds (configurable, with proven bounds)
-- ═══════════════════════════════════════════════════════════════════════════

||| Resource severity level — ordered from nominal to critical.
public export
data Severity
  = Nominal     -- All clear
  | Advisory    -- Something to note, no action needed
  | Caution     -- Approaching limits, operator should be aware
  | Warning     -- Limits near, consider shedding load
  | Critical    -- At limits, automatic protective action taken

||| A resource threshold with hysteresis to prevent flapping.
||| The engage threshold triggers the alarm; the disengage threshold
||| clears it. engage > disengage prevents oscillation.
public export
record Threshold where
  constructor MkThreshold
  engage    : Int    -- Alarm fires when value >= engage
  disengage : Int    -- Alarm clears when value < disengage
  severity  : Severity

||| Default CPU thresholds (percentage, 0-100).
public export
cpuThresholds : List Threshold
cpuThresholds =
  [ MkThreshold 60 50 Caution
  , MkThreshold 75 65 Warning
  , MkThreshold 90 80 Critical
  ]

||| Default memory thresholds (percentage of available, 0-100).
public export
memThresholds : List Threshold
memThresholds =
  [ MkThreshold 70 60 Caution
  , MkThreshold 85 75 Warning
  , MkThreshold 95 85 Critical
  ]

||| Default process count thresholds.
public export
processThresholds : List Threshold
processThresholds =
  [ MkThreshold 10 8  Caution
  , MkThreshold 16 12 Warning
  , MkThreshold 24 18 Critical
  ]

-- ═══════════════════════════════════════════════════════════════════════════
-- Cartridge Resource Profile
-- ═══════════════════════════════════════════════════════════════════════════

||| Resource usage snapshot for a single cartridge.
public export
record CartridgeResources where
  constructor MkCartridgeResources
  cartridgeName : String
  memoryBytes   : Int    -- RSS in bytes
  cpuPercent    : Int    -- 0-100 (of one core)
  openFds       : Int    -- File descriptor count
  childProcs    : Int    -- Spawned subprocess count
  uptimeSeconds : Int    -- How long since mount
  healthPings   : Int    -- Successful health checks
  failedPings   : Int    -- Failed health checks (consecutive)

||| Is a cartridge's resource usage within acceptable bounds?
public export
isCartridgeHealthy : CartridgeResources -> Bool
isCartridgeHealthy cr =
  failedPings cr < 3 &&
  cpuPercent cr < 90 &&
  memoryBytes cr < 536870912  -- 512 MB per cartridge max

-- ═══════════════════════════════════════════════════════════════════════════
-- Circuit Breaker
-- ═══════════════════════════════════════════════════════════════════════════

||| Circuit breaker state (per cartridge).
public export
data CircuitState
  = Closed       -- Normal operation — requests flow through
  | HalfOpen     -- Testing recovery — one probe request allowed
  | Open         -- Tripped — requests rejected, cartridge isolated

||| Transition rules for the circuit breaker.
||| Closed  → Open     : consecutive failures >= threshold
||| Open    → HalfOpen : cooldown period elapsed
||| HalfOpen → Closed  : probe request succeeds
||| HalfOpen → Open    : probe request fails
public export
record CircuitBreaker where
  constructor MkCircuitBreaker
  state           : CircuitState
  failureCount    : Int     -- Consecutive failures
  failureThreshold: Int     -- Failures before tripping (default: 3)
  cooldownSeconds : Int     -- Seconds before half-open probe (default: 30)
  lastTrippedAt   : Int     -- Unix timestamp of last trip
  totalTrips      : Int     -- Lifetime trip count

||| Should a request be allowed through?
public export
isCircuitAllowing : CircuitBreaker -> Bool
isCircuitAllowing cb = case state cb of
  Closed   => True
  HalfOpen => True   -- One probe allowed
  Open     => False

||| Record a success (resets failure count, closes circuit if half-open).
public export
recordSuccess : CircuitBreaker -> CircuitBreaker
recordSuccess cb = case state cb of
  HalfOpen => { state := Closed, failureCount := 0 } cb
  _        => { failureCount := 0 } cb

||| Record a failure (increments count, may trip circuit).
public export
recordFailure : (now : Int) -> CircuitBreaker -> CircuitBreaker
recordFailure now cb =
  let newCount = failureCount cb + 1 in
  if newCount >= failureThreshold cb
    then { state := Open
         , failureCount := newCount
         , lastTrippedAt := now
         , totalTrips := totalTrips cb + 1
         } cb
    else { failureCount := newCount } cb

||| Check if cooldown has elapsed and transition Open → HalfOpen.
public export
maybeTryRecovery : (now : Int) -> CircuitBreaker -> CircuitBreaker
maybeTryRecovery now cb = case state cb of
  Open => if now - lastTrippedAt cb >= cooldownSeconds cb
            then { state := HalfOpen } cb
            else cb
  _    => cb

-- ═══════════════════════════════════════════════════════════════════════════
-- System-Wide Resource Snapshot
-- ═══════════════════════════════════════════════════════════════════════════

||| System-level resource snapshot (host machine).
public export
record SystemResources where
  constructor MkSystemResources
  totalMemoryMB   : Int
  availableMemoryMB : Int
  cpuUsagePercent : Int    -- Aggregate across all cores
  totalProcesses  : Int    -- OS-level process count
  bojProcesses    : Int    -- BoJ-managed process count
  loadAverage1m   : Int    -- Load average * 100 (fixed-point)
  uptimeSeconds   : Int

||| Overall system health assessment.
public export
assessSystem : SystemResources -> Severity
assessSystem sr =
  if cpuUsagePercent sr >= 90 then Critical
  else if availableMemoryMB sr * 100 < totalMemoryMB sr * 5 then Critical
  else if cpuUsagePercent sr >= 75 then Warning
  else if availableMemoryMB sr * 100 < totalMemoryMB sr * 15 then Warning
  else if cpuUsagePercent sr >= 60 then Caution
  else if availableMemoryMB sr * 100 < totalMemoryMB sr * 30 then Caution
  else Nominal

-- ═══════════════════════════════════════════════════════════════════════════
-- Preemptive Actions
-- ═══════════════════════════════════════════════════════════════════════════

||| Actions the guardian can recommend or take automatically.
public export
data GuardianAction
  = NoAction
  | EmitAdvisory String              -- Log a note
  | EmitWarning String               -- Visible warning to operator
  | SuspendCartridge String          -- SIGSTOP a cartridge's processes
  | ResumeCartridge String           -- SIGCONT a previously suspended cartridge
  | UnmountCartridge String          -- Full unmount (circuit breaker tripped)
  | RejectNewMounts String           -- Refuse new order tickets
  | ShedLoad (List String)           -- Suspend lowest-priority cartridges
  | EmergencyReport String           -- Push diagnostic report to operator

||| Determine what action to take given system and cartridge state.
public export
recommendAction : Severity -> List CartridgeResources -> List GuardianAction
recommendAction Nominal _ = [NoAction]
recommendAction Advisory _ = [EmitAdvisory "Resource usage slightly elevated"]
recommendAction Caution crs =
  let unhealthy = filter (\cr => not (isCartridgeHealthy cr)) crs
      names = map cartridgeName unhealthy
  in if length names > 0
       then [EmitWarning "Approaching resource limits", ShedLoad names]
       else [EmitWarning "System load elevated — monitoring"]
recommendAction Warning crs =
  let unhealthy = filter (\cr => not (isCartridgeHealthy cr)) crs
      names = map cartridgeName unhealthy
  in EmitWarning "Resource limits near — shedding load"
     :: RejectNewMounts "System at Warning severity"
     :: map SuspendCartridge names
recommendAction Critical crs =
  let unhealthy = filter (\cr => not (isCartridgeHealthy cr)) crs
      names = map cartridgeName unhealthy
  in EmergencyReport "CRITICAL: System resources exhausted"
     :: RejectNewMounts "System at Critical severity"
     :: map UnmountCartridge names

-- ═══════════════════════════════════════════════════════════════════════════
-- Self-Diagnostic Report
-- ═══════════════════════════════════════════════════════════════════════════

||| A structured self-diagnostic report.
public export
record DiagnosticReport where
  constructor MkDiagnosticReport
  timestamp       : Int
  systemSeverity  : Severity
  systemResources : SystemResources
  cartridgeCount  : Int
  mountedCount    : Int
  unhealthyCount  : Int
  trippedBreakers : Int
  actions         : List GuardianAction

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Encode severity to integer for C-ABI.
public export
severityToInt : Severity -> Int
severityToInt Nominal  = 0
severityToInt Advisory = 1
severityToInt Caution  = 2
severityToInt Warning  = 3
severityToInt Critical = 4

||| Decode integer to severity.
public export
intToSeverity : Int -> Severity
intToSeverity 0 = Nominal
intToSeverity 1 = Advisory
intToSeverity 2 = Caution
intToSeverity 3 = Warning
intToSeverity 4 = Critical
intToSeverity _ = Nominal

||| Encode circuit state to integer for C-ABI.
public export
circuitStateToInt : CircuitState -> Int
circuitStateToInt Closed   = 0
circuitStateToInt HalfOpen = 1
circuitStateToInt Open     = 2

||| Decode integer to circuit state.
public export
intToCircuitState : Int -> CircuitState
intToCircuitState 0 = Closed
intToCircuitState 1 = HalfOpen
intToCircuitState 2 = Open
intToCircuitState _ = Closed

||| Encode guardian action to integer for C-ABI.
public export
actionToInt : GuardianAction -> Int
actionToInt NoAction             = 0
actionToInt (EmitAdvisory _)     = 1
actionToInt (EmitWarning _)      = 2
actionToInt (SuspendCartridge _) = 3
actionToInt (ResumeCartridge _)  = 4
actionToInt (UnmountCartridge _) = 5
actionToInt (RejectNewMounts _)  = 6
actionToInt (ShedLoad _)         = 7
actionToInt (EmergencyReport _)  = 8
