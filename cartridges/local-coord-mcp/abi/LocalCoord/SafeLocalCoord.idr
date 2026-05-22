-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| LocalCoord.SafeLocalCoord: Formal verification of localhost-only binding.
|||
||| Cartridge: local-coord-mcp
||| Matrix cell: Agent x {MCP, Agentic} protocols
|||
||| Core security guarantee: the coordination service CANNOT bind to any
||| address other than the loopback interface. This is enforced at the type
||| level — there is no runtime branch that could accidentally expose the
||| service to the network.
|||
||| Secondary guarantee: session tokens are scoped per-instance, preventing
||| rogue local processes from injecting messages without registering.
|||
||| This cartridge explicitly does NOT participate in Umoja federation.
||| No gossip, no attestation, no remote node discovery.
module LocalCoord.SafeLocalCoord

import Data.List
import Data.Nat
import Data.String

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Loopback Address Safety
-- ═══════════════════════════════════════════════════════════════════════════

||| The only two addresses this cartridge may bind to.
||| Constructive proof — no wildcard, no LAN, no external IP.
public export
data LoopbackAddr : Type where
  IPv4Loop : LoopbackAddr   -- 127.0.0.1
  IPv6Loop : LoopbackAddr   -- ::1

||| Convert a LoopbackAddr to its string representation.
||| This is the ONLY path from type to string — guarantees the output.
public export
loopbackToString : LoopbackAddr -> String
loopbackToString IPv4Loop = "127.0.0.1"
loopbackToString IPv6Loop = "::1"

||| Proof that a string IS a valid loopback address.
||| Only two inhabitants — you cannot construct this for "0.0.0.0" or
||| any other address.
public export
data IsLoopback : String -> Type where
  IsIPv4Loop : IsLoopback "127.0.0.1"
  IsIPv6Loop : IsLoopback "::1"

||| Attempt to parse a string as a loopback address.
||| Returns Nothing for any non-loopback string.
public export
parseLoopback : (addr : String) -> Maybe (IsLoopback addr)
parseLoopback "127.0.0.1" = Just IsIPv4Loop
parseLoopback "::1"       = Just IsIPv6Loop
parseLoopback _           = Nothing

||| Convert a loopback proof to the concrete address type.
public export
fromLoopbackProof : IsLoopback addr -> LoopbackAddr
fromLoopbackProof IsIPv4Loop = IPv4Loop
fromLoopbackProof IsIPv6Loop = IPv6Loop

||| Round-trip: loopbackToString after fromLoopbackProof recovers the address.
export
loopbackRoundtrip : (prf : IsLoopback addr) -> loopbackToString (fromLoopbackProof prf) = addr
loopbackRoundtrip IsIPv4Loop = Refl
loopbackRoundtrip IsIPv6Loop = Refl

||| Proof that "0.0.0.0" is NOT a loopback address.
||| Demonstrates the negative case — wildcard bind is impossible.
export
wildcardNotLoopback : IsLoopback "0.0.0.0" -> Void
wildcardNotLoopback _ impossible

||| Proof that any empty string is NOT a loopback address.
export
emptyNotLoopback : IsLoopback "" -> Void
emptyNotLoopback _ impossible

-- ═══════════════════════════════════════════════════════════════════════════
-- Port Safety
-- ═══════════════════════════════════════════════════════════════════════════

||| The assigned port for this cartridge.
public export
coordPort : Nat
coordPort = 7745

||| Valid port range: 1024–65535 (non-privileged).
public export
data ValidPort : Nat -> Type where
  MkValidPort : (p : Nat)
             -> {auto lo : LTE 1024 p}
             -> {auto hi : LTE p 65535}
             -> ValidPort p

||| Proof that 7745 is a valid non-privileged port.
export
coordPortValid : ValidPort 7745
coordPortValid = MkValidPort 7745

-- ═══════════════════════════════════════════════════════════════════════════
-- Bind Configuration — ties address + port together
-- ═══════════════════════════════════════════════════════════════════════════

||| A verified bind configuration. Can only be constructed with a loopback
||| address and a valid port. The type system prevents any other combination.
public export
record BindConfig where
  constructor MkBindConfig
  addr     : LoopbackAddr
  port     : Nat
  0 portOk : ValidPort port

||| The canonical bind configuration for local-coord-mcp.
public export
coordBindConfig : BindConfig
coordBindConfig = MkBindConfig IPv4Loop coordPort coordPortValid

-- ═══════════════════════════════════════════════════════════════════════════
-- Session Token
-- ═══════════════════════════════════════════════════════════════════════════

||| A session token is a non-empty string issued on registration.
||| All coordination messages must carry a valid token.
public export
data SessionToken : Type where
  MkSessionToken : (tok : String)
                -> {auto nonEmpty : NonEmpty (unpack tok)}
                -> SessionToken

||| Extract the raw token string.
public export
tokenValue : SessionToken -> String
tokenValue (MkSessionToken tok) = tok

||| Proof that two tokens are equal (used for validation).
public export
data TokenMatch : SessionToken -> SessionToken -> Type where
  TokensMatch : (t1, t2 : SessionToken)
             -> tokenValue t1 = tokenValue t2
             -> TokenMatch t1 t2

-- ═══════════════════════════════════════════════════════════════════════════
-- Peer Identity (Hybrid Model)
-- ═══════════════════════════════════════════════════════════════════════════

||| Known client type prefixes for the hybrid identity model.
||| e.g. "claude", "gemini", "copilot", "custom", "openai", "mistral"
||| (Task #33: extended 2026-04 to cover OpenAI and Mistral families.)
public export
data ClientKind : Type where
  Claude  : ClientKind
  Gemini  : ClientKind
  Copilot : ClientKind
  Custom  : ClientKind
  Openai  : ClientKind
  Mistral : ClientKind

public export
Show ClientKind where
  show Claude  = "claude"
  show Gemini  = "gemini"
  show Copilot = "copilot"
  show Custom  = "custom"
  show Openai  = "openai"
  show Mistral = "mistral"

||| A peer identity: human-readable prefix + 4-character hex suffix.
||| e.g. "claude-7f3a", "gemini-b2c1"
public export
record PeerId where
  constructor MkPeerId
  kind   : ClientKind
  suffix : String    -- 4-char hex hash

||| Render a PeerId as its display string.
public export
peerIdToString : PeerId -> String
peerIdToString p = show (kind p) ++ "-" ++ suffix p

||| Maximum number of concurrent peers on a single machine.
||| Bounded to prevent resource exhaustion on localhost.
public export
maxPeers : Nat
maxPeers = 16

-- ═══════════════════════════════════════════════════════════════════════════
-- Federation Opt-Out
-- ═══════════════════════════════════════════════════════════════════════════

||| Proof that this cartridge does not participate in federation.
||| The type has exactly one inhabitant — LocalOnly — and no constructor
||| for any federated mode.
public export
data FederationPolicy : Type where
  LocalOnly : FederationPolicy

||| This cartridge's federation policy. Always LocalOnly.
public export
coordFederationPolicy : FederationPolicy
coordFederationPolicy = LocalOnly

||| Proof that federation is disabled. Any code path requiring federation
||| participation would need a `Federated` constructor, which does not exist.
public export
data IsFederated : FederationPolicy -> Type where
  -- Intentionally empty — no constructor for LocalOnly.
  -- This type is uninhabited when the policy is LocalOnly.

||| Proof that LocalOnly is not federated.
export
localOnlyNotFederated : IsFederated LocalOnly -> Void
localOnlyNotFederated _ impossible

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Encoding
-- ═══════════════════════════════════════════════════════════════════════════

public export
loopbackAddrToInt : LoopbackAddr -> Int
loopbackAddrToInt IPv4Loop = 4
loopbackAddrToInt IPv6Loop = 6

public export
intToLoopbackAddr : Int -> LoopbackAddr
intToLoopbackAddr 6 = IPv6Loop
intToLoopbackAddr _ = IPv4Loop  -- default to IPv4

public export
clientKindToInt : ClientKind -> Int
clientKindToInt Claude  = 0
clientKindToInt Gemini  = 1
clientKindToInt Copilot = 2
clientKindToInt Custom  = 3
clientKindToInt Openai  = 4
clientKindToInt Mistral = 5

public export
intToClientKind : Int -> ClientKind
intToClientKind 0 = Claude
intToClientKind 1 = Gemini
intToClientKind 2 = Copilot
intToClientKind 4 = Openai
intToClientKind 5 = Mistral
intToClientKind _ = Custom

||| FFI: Get the bind port.
export
coord_get_port : Int
coord_get_port = 7745

||| FFI: Check if an address integer represents loopback.
||| Returns 1 for IPv4 (4) or IPv6 (6) loopback, 0 otherwise.
export
coord_is_loopback : Int -> Int
coord_is_loopback 4 = 1
coord_is_loopback 6 = 1
coord_is_loopback _ = 0

||| FFI: Check if federation is enabled. Always returns 0 (disabled).
export
coord_federation_enabled : Int
coord_federation_enabled = 0
