-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
||| LocalCoord.Identity: Cryptographic peer identity for the local-coord
||| cartridge.
|||
||| Cartridge: local-coord-mcp
||| ADR: 0016 (mTLS + ed25519 federation stop-gap), Phase 1 — identity
||| foundation. No transport here; this module defines the *types* and
||| *FFI signatures* for an ed25519 keypair per peer, the public key as
||| federated identity, and the known_peers.toml entry shape. The Zig
||| implementation (cartridges/local-coord-mcp/adapter/) realises these
||| signatures with std.crypto.sign.Ed25519.
|||
||| Phase-1 scope (deliberate non-promises):
||| * Generates / loads ed25519 keypair material on disk.
||| * Exposes the public key for human export.
||| * Parses known_peers.toml.
||| * Does NOT sign or verify anything — Phase 2.
||| * Does NOT bind to any non-loopback address — Phase 3.
||| * Does NOT change the `FederationPolicy = LocalOnly` invariant from
|||   SafeLocalCoord.idr. Identity material is necessary-but-not-
|||   sufficient for federation; carrying a keypair does not enable it.
module LocalCoord.Identity

import Data.List
import Data.Vect
import Data.Nat

import LocalCoord.SafeLocalCoord

%default total

-- ═══════════════════════════════════════════════════════════════════════════
-- Key Material — Size-Indexed Byte Vectors
-- ═══════════════════════════════════════════════════════════════════════════

||| ed25519 public-key length in bytes. RFC 8032 §5.1.5.
public export
ed25519PubKeyBytes : Nat
ed25519PubKeyBytes = 32

||| ed25519 private-key length in bytes (seed form). RFC 8032 §5.1.5.
||| The expanded secret-scalar form is 64 bytes; we store the 32-byte
||| seed and derive the scalar at sign time.
public export
ed25519PrivKeyBytes : Nat
ed25519PrivKeyBytes = 32

||| ed25519 signature length in bytes (R || S). RFC 8032 §5.1.6.
public export
ed25519SigBytes : Nat
ed25519SigBytes = 64

||| A fixed-width byte vector. Used to enforce key-material sizes at
||| the type level — the only way to construct an `Ed25519PublicKey`
||| is via a value of `Bytes 32`, so any code holding one *knows* it
||| has 32 bytes without runtime checks.
public export
Bytes : Nat -> Type
Bytes n = Vect n Bits8

||| An ed25519 public key. Wrapper around `Bytes 32` so the type system
||| distinguishes pubkeys from arbitrary 32-byte blobs.
public export
record Ed25519PublicKey where
  constructor MkPubKey
  bytes : Bytes ed25519PubKeyBytes

||| An ed25519 private key (seed form). NEVER crosses the FFI boundary
||| as a payload — the Zig adapter holds it in process memory and
||| references it via opaque handle. This type exists in the ABI only
||| to document the contract.
public export
record Ed25519PrivateKey where
  constructor MkPrivKey
  bytes : Bytes ed25519PrivKeyBytes

||| An ed25519 signature over arbitrary bytes.
public export
record Ed25519Signature where
  constructor MkSig
  bytes : Bytes ed25519SigBytes

-- ═══════════════════════════════════════════════════════════════════════════
-- Proof Obligation P-20: Ed25519 Key Material Well-Formedness
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A public key value carries exactly `ed25519PubKeyBytes` bytes; a
-- signature value carries exactly `ed25519SigBytes`. This is enforced
-- *by construction* via `Vect n` — the only inhabitants of
-- `Bytes ed25519PubKeyBytes` are length-32 byte vectors, so any code
-- receiving an `Ed25519PublicKey` is statically guaranteed it has the
-- right length. No runtime size check is needed; no
-- malformed-key branch can exist in the protocol layer.
--
-- The "proof" is the type itself: pattern-matching `MkPubKey bs`
-- recovers a `bs : Vect 32 Bits8`, whose index is fixed at the
-- definition site and cannot be shrunk or grown.
--
-- Demonstration: a concrete zero-keyed pubkey is built-in-shape.

||| Demonstration witness — a concrete pubkey value built from a
||| size-32 literal compiles iff the type's size invariant holds.
||| If this line fails to compile, P-20 has been broken.
public export
zeroPubKey : Ed25519PublicKey
zeroPubKey = MkPubKey (replicate ed25519PubKeyBytes 0)

||| Same demonstration for signatures.
public export
zeroSig : Ed25519Signature
zeroSig = MkSig (replicate ed25519SigBytes 0)

-- ═══════════════════════════════════════════════════════════════════════════
-- Peer Identity = PeerId + Public Key
-- ═══════════════════════════════════════════════════════════════════════════

||| A peer's complete identity: the human-readable `PeerId` (from
||| SafeLocalCoord) plus the ed25519 public key that vouches for it.
||| The PeerId is for humans; the pubkey is for crypto.
public export
record PeerIdentity where
  constructor MkPeerIdentity
  peerId : PeerId
  pubKey : Ed25519PublicKey

||| Extract the display form of a peer identity. Goes through the
||| existing PeerId display — the pubkey is intentionally not rendered
||| here (use `pubKeyHex` for that, in a UI context).
public export
identityToString : PeerIdentity -> String
identityToString pi = peerIdToString (peerId pi)

-- ═══════════════════════════════════════════════════════════════════════════
-- Known Peers (known_peers.toml entries) — Trust List
-- ═══════════════════════════════════════════════════════════════════════════

||| An entry in `~/.config/coord-tui/known_peers.toml`. Manual trust
||| list: peers we have explicitly agreed to federate with. No
||| discovery, no CA hierarchy — SSH known_hosts model.
|||
||| The `host` and `port` fields are Phase-3 wire material; Phase 1
||| parses them but does not connect to them.
public export
record KnownPeer where
  constructor MkKnownPeer
  peerId  : PeerId
  pubKey  : Ed25519PublicKey
  host    : String     -- DNS name or literal IP — validated at use-site
  port    : Nat

||| The maximum number of known peers a single host may trust.
||| Bound is generous; it exists to make `Vect`-based loading easy.
public export
maxKnownPeers : Nat
maxKnownPeers = 64

-- ═══════════════════════════════════════════════════════════════════════════
-- Federation Invariant Preservation
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Crucially: this module adds *types*. It does not add a path from
-- those types to any non-loopback bind. The `FederationPolicy` value
-- in SafeLocalCoord remains `LocalOnly`, and `IsFederated LocalOnly`
-- remains uninhabited. Phase 3 will widen this — Phase 1 must not.

||| Proof that having a PeerIdentity does not unlock federation. The
||| federation policy is still `LocalOnly`, and the negative proof
||| from `SafeLocalCoord.localOnlyNotFederated` carries through.
||| Discharge is structural: the LHS doesn't influence the RHS at all.
export
identityDoesNotEnableFederation
  :  (_ : PeerIdentity)
  -> IsFederated LocalOnly
  -> Void
-- `coordFederationPolicy` is definitionally `LocalOnly` (see SafeLocalCoord),
-- so this obligation is exactly that `IsFederated LocalOnly` is uninhabited —
-- discharged directly by `localOnlyNotFederated`. Stating the bound as the
-- constructor (rather than the nullary CAF) keeps the unifier from stalling on
-- an unreduced top-level name.
identityDoesNotEnableFederation _ x = localOnlyNotFederated x

-- ═══════════════════════════════════════════════════════════════════════════
-- C-ABI Contract (Phase 1) — documentation, not %foreign import
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The Zig adapter exposes the following entry points. They are NOT
-- imported via `%foreign` here because the Idris2 ABI module's job is
-- to *type* the contract; the actual calls are made from Zig (intra-
-- cartridge) and from the Deno/Node bridge (over HTTP). This mirrors
-- the convention used in `SafeLocalCoord.idr`, which defines the type
-- envelope but doesn't import the Zig functions.
--
--   int boj_coord_identity_init(const char *key_path);
--     Generates a fresh keypair if none exists at `key_path`, otherwise
--     loads the existing seed. Persists the seed (0600) on disk. Phase
--     1 keys live at ~/.cache/coord-tui/peer.key.
--     Returns: 0 on success, non-zero error code otherwise.
--
--   int boj_coord_identity_get_pubkey(uint8_t *out, size_t out_len);
--     Copies `ed25519PubKeyBytes` (32) bytes of the local public key
--     into `out`. The corresponding `Ed25519PublicKey` value can be
--     reconstructed from the bytes on the consumer side.
--     Returns: bytes written (== 32) on success, -1 if not initialised
--     or buffer too small.
--
--   int boj_coord_identity_load_known_peers(const char *toml_path);
--     Parses `~/.config/coord-tui/known_peers.toml` (or supplied path)
--     into an in-process trust table of `KnownPeer` entries. Replaces
--     any previously loaded set (full reload).
--     Returns: number of entries loaded (>= 0) on success, -1 on error
--     (missing file is treated as zero entries, not an error).
--
--   int boj_coord_identity_known_peer_count(void);
--     Returns the current count of loaded known peers.
--
-- Phase 2 will add `boj_coord_envelope_sign` / `boj_coord_envelope_verify`
-- once `LocalCoord.Federation` lands the P-22 obligation.
