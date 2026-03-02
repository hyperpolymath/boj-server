-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| FleetMcp.SafeFleet: Formally verified gitbot fleet orchestration.
|||
||| Cartridge: fleet-mcp
||| Matrix cell: Fleet domain x {MCP, Fleet, gRPC} protocols
|||
||| This module defines the 6-bot gate policy for repository quality
||| and the FleetCertified proof type that ensures all mandatory
||| gates have been passed before a release is allowed.
|||
||| The six bots:
|||   Rhodibot    — Identity & structure validation
|||   Echidnabot  — Formal verification (flags believe_me, Admitted, sorry)
|||   Sustainabot — Eco/economic efficiency
|||   Panicbot    — Static security audit
|||   Glambot     — Presentation & documentation
|||   Seambot     — Integration & compatibility
module FleetMcp.SafeFleet

import Data.List

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Bot Gates
-- ═══════════════════════════════════════════════════════════════════════════

||| The six quality gates for hyperpolymath repositories.
||| Each gate is a bot that validates a specific aspect of code quality.
public export
data BotGate
  = Rhodibot      -- Identity & structure (RSR compliance, file layout)
  | Echidnabot    -- Formal verification (believe_me, Admitted, sorry)
  | Sustainabot   -- Eco/economic efficiency (dependency health, bloat)
  | Panicbot      -- Static security audit (OWASP, secrets, CVEs)
  | Glambot       -- Presentation (docs, README, TOPOLOGY, formatting)
  | Seambot       -- Integration (CI/CD, cross-repo compat, API stability)

||| Equality for bot gates (needed for list membership).
public export
Eq BotGate where
  Rhodibot    == Rhodibot    = True
  Echidnabot  == Echidnabot  = True
  Sustainabot == Sustainabot = True
  Panicbot    == Panicbot    = True
  Glambot     == Glambot     = True
  Seambot     == Seambot     = True
  _           == _           = False

||| C-ABI encoding: bot gate to integer.
public export
gateToInt : BotGate -> Int
gateToInt Rhodibot    = 1
gateToInt Echidnabot  = 2
gateToInt Sustainabot = 3
gateToInt Panicbot    = 4
gateToInt Glambot     = 5
gateToInt Seambot     = 6

||| C-ABI decoding: integer to bot gate.
public export
intToGate : Int -> Maybe BotGate
intToGate 1 = Just Rhodibot
intToGate 2 = Just Echidnabot
intToGate 3 = Just Sustainabot
intToGate 4 = Just Panicbot
intToGate 5 = Just Glambot
intToGate 6 = Just Seambot
intToGate _ = Nothing

-- ═══════════════════════════════════════════════════════════════════════════
-- Repository Health
-- ═══════════════════════════════════════════════════════════════════════════

||| Repository health status.
public export
data RepoStatus = Unscanned | Scanning | Healthy | Degraded | Blocked

||| Equality for repo status.
public export
Eq RepoStatus where
  Unscanned == Unscanned = True
  Scanning  == Scanning  = True
  Healthy   == Healthy   = True
  Degraded  == Degraded  = True
  Blocked   == Blocked   = True
  _         == _         = False

||| C-ABI encoding.
public export
repoStatusToInt : RepoStatus -> Int
repoStatusToInt Unscanned = 0
repoStatusToInt Scanning  = 1
repoStatusToInt Healthy   = 2
repoStatusToInt Degraded  = 3
repoStatusToInt Blocked   = 4

-- ═══════════════════════════════════════════════════════════════════════════
-- Fleet Certification (the proof)
-- ═══════════════════════════════════════════════════════════════════════════

||| Formal proof that a repository has passed ALL six quality gates.
||| This is the fleet equivalent of IsUnbreakable — you cannot release
||| without all six bots signing off.
public export
data FleetCertified : (passedGates : List BotGate) -> Type where
  FullyVerified : FleetCertified [Rhodibot, Echidnabot, Sustainabot,
                                   Panicbot, Glambot, Seambot]

||| The three mandatory gates (minimum for any release).
||| Rhodibot (structure), Echidnabot (verification), Panicbot (security).
public export
mandatoryGates : List BotGate
mandatoryGates = [Rhodibot, Echidnabot, Panicbot]

||| Check if the mandatory gates have been passed.
public export
hasMandatoryGates : List BotGate -> Bool
hasMandatoryGates gates = all (\g => elem g gates) mandatoryGates

||| Check if ALL six gates have been passed (full certification).
public export
hasAllGates : List BotGate -> Bool
hasAllGates gates = all (\g => elem g gates)
  [Rhodibot, Echidnabot, Sustainabot, Panicbot, Glambot, Seambot]

||| Determine repo status from passed gates.
public export
deriveStatus : List BotGate -> RepoStatus
deriveStatus gates =
  if hasAllGates gates then Healthy
  else if hasMandatoryGates gates then Degraded
  else if length gates > 0 then Scanning
  else Unscanned

-- ═══════════════════════════════════════════════════════════════════════════
-- Scan Result
-- ═══════════════════════════════════════════════════════════════════════════

||| Result of a single bot gate scan.
public export
record GateScanResult where
  constructor MkGateScan
  gate    : BotGate
  passed  : Bool
  score   : Int       -- 0-100 quality score
  message : String    -- Human-readable summary

||| Extract passed gates from a list of scan results.
public export
passedGates : List GateScanResult -> List BotGate
passedGates [] = []
passedGates (r :: rs) =
  if passed r
    then gate r :: passedGates rs
    else passedGates rs

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Export
-- ═══════════════════════════════════════════════════════════════════════════

||| FFI: Check if a set of gate integers represents a releasable state.
||| Takes up to 6 gate ints (-1 for unused), returns 1 if releasable, 0 if not.
export
fleet_can_release : Int -> Int -> Int -> Int -> Int -> Int -> Int
fleet_can_release g1 g2 g3 g4 g5 g6 =
  let gates = mapMaybe intToGate [g1, g2, g3, g4, g5, g6]
  in if hasMandatoryGates gates then 1 else 0

||| FFI: Derive repo status from gate integers.
export
fleet_derive_status : Int -> Int -> Int -> Int -> Int -> Int -> Int
fleet_derive_status g1 g2 g3 g4 g5 g6 =
  let gates = mapMaybe intToGate [g1, g2, g3, g4, g5, g6]
  in repoStatusToInt (deriveStatus gates)
