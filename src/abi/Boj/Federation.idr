-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| Boj.Federation: Umoja federated network protocol.
|||
||| Implements the distributed hosting model where community nodes
||| volunteer compute time (like Tor/IPFS). Each node proves its
||| identity via cryptographic hash attestation — if you tamper
||| with the server binary, you're excluded from the community
||| network but can still run locally.
|||
||| Design:
|||   - IPv6-only addressing (modern, secure, no NAT headaches)
|||   - Gossip protocol for node discovery (Byzantine fault tolerant)
|||   - Hash attestation ties binary to canonical build
|||   - Load-aware routing sends requests to healthy nodes
|||   - PMPL provenance metadata is the legal expression of attestation
module Boj.Federation

import Data.List
import Data.String

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Node Identity
-- ═══════════════════════════════════════════════════════════════════════════

||| Region hint for georedundancy display.
public export
data Region
  = EuropeWest      -- UK, France, etc.
  | EuropeCentral   -- Germany, Austria, Czech, etc.
  | Oceania         -- Australia, New Zealand
  | Americas        -- US, Canada, South America
  | AsiaEast        -- Japan, Korea, etc.
  | AsiaSouth       -- India, etc.
  | Africa          -- Continent
  | Other           -- Unlisted

||| A node in the Umoja network.
public export
record Node where
  constructor MkNode
  nodeId     : String    -- Unique identifier
  ipv6       : String    -- IPv6 address (no IPv4)
  binaryHash : String    -- SHA-256 of the Idris2/Zig engine binary
  region     : Region    -- Geographic hint for routing
  lastSeen   : Int       -- Unix timestamp of last heartbeat
  loadFactor : Int       -- 0-100 (percentage of capacity in use)
  cartridges : List String -- Names of cartridges this node hosts

-- ═══════════════════════════════════════════════════════════════════════════
-- Hash Attestation (the trust mechanism)
-- ═══════════════════════════════════════════════════════════════════════════

||| Proof that a node's binary matches the canonical system hash.
||| This is the core trust mechanism for the distributed network.
||| If a node's binary hash doesn't match, it cannot participate
||| in the community network (but can still run locally for personal use).
public export
data Attested : (n : Node) -> (canonicalHash : String) -> Type where
  ValidAttestation : (n : Node) ->
                     (canonicalHash : String) ->
                     (binaryHash n = canonicalHash) ->
                     Attested n canonicalHash

-- ═══════════════════════════════════════════════════════════════════════════
-- Node Health
-- ═══════════════════════════════════════════════════════════════════════════

||| Maximum load before a node is considered overloaded.
||| Nodes above this threshold are deprioritised in routing.
public export
maxLoadThreshold : Int
maxLoadThreshold = 80

||| Is a node healthy enough to accept requests?
public export
isHealthy : Node -> Bool
isHealthy n = loadFactor n < maxLoadThreshold

||| Select the best available node from a list (lowest load, healthy).
public export
selectBestNode : List Node -> Maybe Node
selectBestNode [] = Nothing
selectBestNode (n :: ns) =
  if isHealthy n
    then case selectBestNode ns of
           Nothing => Just n
           Just m  => if loadFactor n <= loadFactor m
                        then Just n
                        else Just m
    else selectBestNode ns

-- ═══════════════════════════════════════════════════════════════════════════
-- Gossip Protocol
-- ═══════════════════════════════════════════════════════════════════════════

||| Check if a node ID already exists in a cache.
public export
nodeExists : String -> List Node -> Bool
nodeExists nid [] = False
nodeExists nid (n :: ns) =
  if nodeId n == nid
    then True
    else nodeExists nid ns

||| Gossip protocol: merge remote neighbor list into local cache.
||| Deduplicates by node ID — existing entries are kept as-is.
||| New nodes are appended. This is eventually consistent.
public export
gossip : (localCache : List Node) -> (remoteNeighbors : List Node) -> List Node
gossip cache [] = cache
gossip cache (n :: ns) =
  if nodeExists (nodeId n) cache
    then gossip cache ns
    else gossip (n :: cache) ns

||| Filter nodes that host a specific cartridge.
public export
nodesForCartridge : String -> List Node -> List Node
nodesForCartridge name [] = []
nodesForCartridge name (n :: ns) =
  if elem name (cartridges n)
    then n :: nodesForCartridge name ns
    else nodesForCartridge name ns

||| Count active nodes (those seen within the last hour).
||| @now: Current unix timestamp.
public export
countActiveNodes : (now : Int) -> List Node -> Nat
countActiveNodes now [] = 0
countActiveNodes now (n :: ns) =
  if now - lastSeen n < 3600
    then S (countActiveNodes now ns)
    else countActiveNodes now ns

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Exports
-- ═══════════════════════════════════════════════════════════════════════════

||| Encode region to integer for C-ABI.
public export
regionToInt : Region -> Int
regionToInt EuropeWest    = 1
regionToInt EuropeCentral = 2
regionToInt Oceania       = 3
regionToInt Americas      = 4
regionToInt AsiaEast      = 5
regionToInt AsiaSouth     = 6
regionToInt Africa        = 7
regionToInt Other         = 0

||| Decode integer to region.
public export
intToRegion : Int -> Region
intToRegion 1 = EuropeWest
intToRegion 2 = EuropeCentral
intToRegion 3 = Oceania
intToRegion 4 = Americas
intToRegion 5 = AsiaEast
intToRegion 6 = AsiaSouth
intToRegion 7 = Africa
intToRegion _ = Other
