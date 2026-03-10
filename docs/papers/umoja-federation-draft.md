<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Gossip-Based Capability Discovery and Synchronisation for Developer Tool Servers

**Internet-Draft:** `draft-jewell-umoja-capability-gossip-00`
**Intended Status:** Experimental
**Author:** Jonathan D.A. Jewell
**Organisation:** hyperpolymath
**Date:** 2026-03

---

## Abstract

This document describes the Umoja federation protocol, a gossip-based
mechanism for discovering and synchronising capability catalogues across
distributed developer tool server instances. Umoja enables isolated
server nodes — such as those implementing the Model Context Protocol
(MCP), Language Server Protocol (LSP), or Debug Adapter Protocol (DAP) —
to form a federated network where each node advertises and discovers
capabilities ("cartridges") provided by its peers.

The protocol uses QUIC [RFC 9000] as its primary transport, with X25519
[RFC 7748] key exchange and ChaCha20-Poly1305 [RFC 8439] AEAD encryption
for peer-to-peer confidentiality and integrity. A UDP fallback mode is
defined for constrained environments or development/testing scenarios
where QUIC support is unavailable.

Catalogue synchronisation is achieved through anti-entropy digest
exchange using SHA-256 hashes of sorted cartridge metadata. The protocol
does not transfer cartridge binaries or executable code — only metadata
sufficient for capability discovery and version negotiation.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Terminology](#2-terminology)
3. [Protocol Overview](#3-protocol-overview)
4. [Discovery Mechanism](#4-discovery-mechanism)
5. [Handshake and Attestation](#5-handshake-and-attestation)
6. [Gossip Protocol](#6-gossip-protocol)
7. [Catalogue Synchronisation](#7-catalogue-synchronisation)
8. [Security Considerations](#8-security-considerations)
9. [IANA Considerations](#9-iana-considerations)
10. [References](#10-references)
11. [Appendix A: Packet Format Diagrams](#appendix-a-packet-format-diagrams)
12. [Appendix B: Example Message Flows](#appendix-b-example-message-flows)
13. [Author's Address](#authors-address)

---

## 1. Introduction

### 1.1. Problem Statement

Modern developer tool ecosystems rely on protocol servers — MCP servers
for AI agent capabilities, LSP servers for editor intelligence, DAP
servers for debugging — that operate as isolated, single-tenant
instances. Each server maintains its own capability catalogue with no
mechanism for sharing discovered capabilities across instances or
environments.

This isolation creates several problems:

- **Capability fragmentation.** A developer working across multiple
  machines or environments cannot discover capabilities available on
  peer instances.

- **Redundant configuration.** Each server must be independently
  configured with identical capability sets, even when they serve the
  same organisation or project.

- **No cross-instance awareness.** An MCP server on one machine has no
  knowledge of cartridges loaded on a teammate's MCP server, even when
  those cartridges would be directly useful.

- **Scaling limitations.** Without federation, scaling developer tool
  infrastructure requires manual replication of capability catalogues
  across every new instance.

### 1.2. Solution Overview

The Umoja federation protocol addresses these problems by defining a
gossip-based mechanism for peer-to-peer capability catalogue discovery
and synchronisation. "Umoja" means "unity" in Swahili, reflecting the
protocol's goal of unifying isolated developer tool server instances
into a coherent federation.

Key design principles:

- **Metadata only.** The protocol exchanges capability metadata (names,
  versions, hashes), never executable code or cartridge binaries. This
  limits the attack surface and keeps message sizes small.

- **QUIC-first, UDP-fallback.** Encrypted transport is the default;
  cleartext UDP is available for development and testing but SHOULD NOT
  be used in production deployments.

- **SWIM-inspired failure detection.** Node liveness is tracked using a
  protocol inspired by the Scalable Weakly-consistent Infection-style
  Process Group Membership protocol (SWIM), with states: alive,
  suspected, dead.

- **Cryptographic attestation.** Peers attest their catalogue state via
  SHA-256 digests. Catalogue hash comparison drives synchronisation
  decisions.

- **Zero-trust perimeter.** An integrated Software Defined Perimeter
  (Auto-SDP) layer rejects traffic from unverified peers before it
  reaches the gossip layer.

### 1.3. Relationship to Existing Work

This protocol is informed by, but distinct from, several IETF efforts
in the AI agent and service discovery space:

- **draft-cui-ai-agent-discovery-invocation-00** defines a DNS-based
  discovery framework for AI agents. Umoja operates below this layer,
  providing gossip-based discovery for the servers that host such agents.

- **draft-narajala-ans-00** (Agent Naming Service) proposes a
  hierarchical naming scheme for AI agents. Umoja complements ANS by
  providing a runtime discovery protocol that could resolve ANS names to
  live server instances.

- **draft-mp-agntcy-ads** (Agent Discovery Service) addresses agent
  capability advertisement. Umoja focuses specifically on server-level
  capability catalogues rather than individual agent capabilities.

- **RFC 9000 (QUIC)** provides the encrypted transport foundation.

Umoja does not replace any of these proposals. It fills a gap at the
infrastructure layer: where agents and tools are *hosted*, rather than
how individual agents are *identified* or *invoked*.

---

## 2. Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT",
"SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and
"OPTIONAL" in this document are to be interpreted as described in
BCP 14 [RFC 2119] [RFC 8174] when, and only when, they appear in all
capitals, as shown here.

- **Node**: A single instance of a developer tool server participating
  in the Umoja federation. Each node has a unique node identifier.

- **Peer**: A remote node that the local node is aware of and
  communicates with via the gossip protocol.

- **Catalogue**: The ordered set of capabilities (cartridges) available
  on a given node. Represented as a sorted list of (name, version, hash)
  tuples.

- **Cartridge**: A discrete, loadable capability module registered with
  a developer tool server. Cartridges expose tools, resources, or
  protocol capabilities.

- **Digest**: A SHA-256 hash computed over the sorted catalogue entries
  of a node. Used for efficient comparison of catalogue state between
  peers without exchanging the full catalogue.

- **Attestation**: The process by which a peer proves its identity and
  catalogue integrity via X25519 key exchange and digest comparison.

- **Seed Node**: A well-known bootstrap node that new peers contact to
  join the federation network. Seed nodes are listed in a static
  configuration file.

- **Gossip Round**: A single cycle of the anti-entropy protocol, in
  which a node selects a subset of peers and exchanges digest
  information.

- **Fanout**: The number of peers contacted during each gossip round.

---

## 3. Protocol Overview

### 3.1. Node Lifecycle

A node progresses through the following states:

```
Bootstrap → Discovery → Handshake → Active → Suspected → Dead
    │                                  ↑          │
    │                                  └──────────┘
    │                                  (recovery)
    └─────────────────────────────────────────────►
                    (fatal error → Dead)
```

- **Bootstrap**: Node initialises its local catalogue digest, generates
  an X25519 keypair, binds to its federation port (default 9999), and
  loads its seed node list.

- **Discovery**: Node sends DISCOVER packets to seed nodes and/or the
  IPv6 multicast group (ff02::b04) to locate peers. Discovery is
  repeated on a configurable interval (default: 60 seconds).

- **Handshake**: Upon discovering a peer, the node initiates a
  handshake: X25519 public key exchange, mutual node ID verification,
  and catalogue digest comparison.

- **Active**: The node participates in gossip rounds, exchanges
  heartbeats, and synchronises catalogue state with peers.

- **Suspected**: A peer that has missed heartbeats beyond the configured
  timeout (default: 30 seconds) transitions to "suspected". The local
  node MAY attempt indirect probes via other peers before declaring
  the suspected peer dead.

- **Dead**: A peer confirmed as unreachable. Dead peers are removed from
  the active peer list after a configurable grace period.

### 3.2. Transport

#### 3.2.1. Encrypted Transport (Default)

The protocol's primary transport uses AEAD-encrypted UDP datagrams with
the following cryptographic primitives. Note: while internally referred
to as "QUIC mode" in the reference implementation, this transport does
not implement the full QUIC protocol [RFC 9000] (no connection IDs,
streams, flow control, or congestion control). It uses QUIC's
cryptographic choices (X25519 + ChaCha20-Poly1305) applied directly to
UDP datagrams:

- **Key exchange**: X25519 Elliptic Curve Diffie-Hellman [RFC 7748].
  Each node generates a long-lived identity keypair at bind time. A
  per-peer shared secret is derived via X25519(local_secret,
  remote_public).

- **Authenticated encryption**: ChaCha20-Poly1305 AEAD [RFC 8439].
  All gossip and heartbeat traffic between peers with established
  shared secrets is encrypted. The AEAD tag provides integrity
  verification.

- **Packet framing**: Encrypted packets are distinguished from cleartext
  packets by a high-bit marker (0x80) in the first byte. The remaining
  7 bits encode the packet type.

QUIC-mode packets carry a 12-byte nonce and 16-byte authentication tag
in addition to the encrypted payload.

#### 3.2.2. UDP Fallback

For environments where QUIC is unavailable or during initial development
and testing, a cleartext UDP mode is defined. In this mode:

- Packet types are indicated by a single-byte tag (0x01–0x07) without
  the high-bit marker.
- No encryption or authentication is applied.
- Nodes SHOULD log a warning when operating in UDP fallback mode.
- UDP fallback mode MUST NOT be used in production deployments handling
  sensitive capability metadata.

#### 3.2.3. Port Assignment

The default federation port is **9999** (UDP). This port is used for
both QUIC-mode and UDP-fallback-mode traffic. The port is configurable
via the `BOJ_FEDERATION_PORT` environment variable.

### 3.3. Packet Types

| Tag (cleartext) | Tag (encrypted) | Name                | Direction       |
|:---------------:|:---------------:|---------------------|-----------------|
| 0x01            | 0x81       | DISCOVER            | Multicast / Unicast |
| 0x02            | 0x82       | DISCOVER_REPLY      | Unicast         |
| 0x03            | 0x83       | GOSSIP_DIGEST       | Unicast         |
| 0x04            | 0x84       | GOSSIP_DIGEST_REPLY | Unicast         |
| 0x05            | 0x85       | HANDSHAKE_INIT      | Unicast         |
| 0x06            | 0x86       | HANDSHAKE_REPLY     | Unicast         |
| 0x07            | 0x87       | HEARTBEAT           | Unicast         |

All packets MUST fit within a single UDP datagram. The maximum packet
payload size is 1024 bytes. Implementations MUST discard packets
exceeding this limit.

---

## 4. Discovery Mechanism

### 4.1. Link-Local Discovery (IPv6 Multicast)

For nodes on the same network segment, Umoja uses IPv6 multicast group
**ff02::b04** (link-local scope) for peer discovery. The multicast
address encodes "b04" (a mnemonic for "boj" in hexadecimal).

A discovering node sends a DISCOVER packet to the multicast group.
Any node listening on the federation port that receives this packet
SHOULD reply with a DISCOVER_REPLY containing its node ID, listen
address, and current catalogue digest.

Link-local discovery is useful for development environments, CI/CD
clusters, and any scenario where nodes share a network segment.

### 4.2. WAN Bootstrap (Seed Nodes)

For wide-area federation, nodes are configured with a list of seed nodes.
Seed nodes are well-known, stable federation endpoints that serve as
bootstrap rendezvous points.

The seed node list is specified in a TOML configuration file:

```toml
[metadata]
version = "0.1.0"
network = "umoja-mainnet"
min-seeds-for-quorum = 2

[[seed]]
id = "seed-eu-west"
region = "eu-west-1"
host = "eu.boj.hyperpolymath.dev"
federation-port = 9999
```

A node MUST attempt to contact at least `min-seeds-for-quorum` seed
nodes during bootstrap. If fewer than `min-seeds-for-quorum` seeds
respond, the node MAY operate in a degraded mode with reduced federation
capabilities.

### 4.3. Discovery Interval

Discovery is performed periodically at a configurable interval
(default: 60 seconds). The interval SHOULD be jittered by +/- 10% to
avoid thundering-herd effects across simultaneously-booted clusters.

---

## 5. Handshake and Attestation

### 5.1. Handshake Flow

Upon discovering a new peer, a node initiates a three-step handshake:

```
    Node A                          Node B
      │                               │
      │── HANDSHAKE_INIT ────────────►│
      │   (A's public key, node ID)   │
      │                               │
      │◄── HANDSHAKE_REPLY ──────────│
      │   (B's public key, node ID,   │
      │    catalogue digest)          │
      │                               │
      │── GOSSIP_DIGEST ────────────►│
      │   (A's catalogue digest,      │
      │    encrypted if QUIC)         │
      │                               │
```

### 5.2. Handshake States

Each peer relationship progresses through the following states:

| State       | Meaning                                               |
|-------------|-------------------------------------------------------|
| `none`      | No handshake attempted                                |
| `pending`   | HANDSHAKE_INIT sent, awaiting reply                   |
| `exchanged` | Keys exchanged, catalogue digests being compared      |
| `verified`  | Peer identity confirmed, digests match or sync in progress |
| `rejected`  | Peer rejected (failed authentication or banned by SDP) |

A peer in `verified` state is eligible for gossip rounds and heartbeat
exchange. A peer in `rejected` state MUST NOT receive gossip traffic and
SHOULD be reported to the Auto-SDP layer.

### 5.3. Key Exchange

The handshake uses X25519 [RFC 7748] for key exchange:

1. Each node generates a long-lived X25519 keypair at bind time.
2. HANDSHAKE_INIT carries the initiator's 32-byte public key.
3. HANDSHAKE_REPLY carries the responder's 32-byte public key.
4. Both nodes derive a shared secret: `shared = X25519(local_secret, remote_public)`.
5. The shared secret is used as the ChaCha20-Poly1305 key for all
   subsequent encrypted communication with that peer.

### 5.4. Catalogue Digest Comparison

During handshake, both nodes exchange their current catalogue digest
(SHA-256 of sorted cartridge metadata). If the digests differ,
catalogue synchronisation (Section 7) is triggered immediately after
the handshake completes.

---

## 6. Gossip Protocol

### 6.1. Protocol Model

The Umoja gossip protocol is inspired by the SWIM (Scalable
Weakly-consistent Infection-style Process Group Membership) protocol,
adapted for capability catalogue synchronisation rather than process
group membership.

### 6.2. Gossip Rounds

Each gossip round proceeds as follows:

1. The local node selects up to `fanout` (default: 3) random peers from
   its active peer list.
2. For each selected peer, the node sends a GOSSIP_DIGEST packet
   containing its current catalogue digest.
3. The recipient compares the received digest against its own catalogue
   digest.
4. If the digests differ, the recipient replies with a
   GOSSIP_DIGEST_REPLY containing its own digest and the full list of
   cartridge metadata entries that differ.
5. The originator processes the reply and updates its view of the peer's
   catalogue.

### 6.3. Configurable Parameters

| Parameter            | Default | Description                                |
|----------------------|---------|--------------------------------------------|
| `gossip-interval-ms` | 5000    | Time between gossip rounds (milliseconds)  |
| `gossip-fanout`      | 3       | Number of peers contacted per round        |
| `heartbeat-interval-ms` | 10000 | Time between heartbeat packets            |
| `heartbeat-timeout-ms`  | 30000 | Time before a peer is marked "suspected"  |
| `max-peers`          | 128     | Maximum number of tracked peers            |
| `min-peers`          | 2       | Minimum peers for healthy federation       |

### 6.4. Failure Detection

Failure detection uses heartbeat monitoring:

1. Each active peer MUST send HEARTBEAT packets at the configured
   heartbeat interval (default: 10 seconds).
2. If no heartbeat is received from a peer within the heartbeat timeout
   (default: 30 seconds), the peer transitions from `alive` to
   `suspected`.
3. A suspected peer MAY be probed indirectly: the local node asks
   another peer to probe the suspected node. If the indirect probe
   succeeds, the peer returns to `alive`.
4. If the suspected peer remains unreachable after `unhealthy-threshold`
   (default: 3) consecutive missed heartbeat cycles, it transitions to
   `dead`.
5. A dead peer MAY be resurrected if it re-establishes contact and
   completes a fresh handshake. After `recovery-threshold` (default: 2)
   successful heartbeats, it returns to `alive`.

### 6.5. Peer Selection

Peer selection for gossip rounds uses a lightweight PRNG (xorshift32,
seeded from the system timestamp). The selection algorithm is not
required to be cryptographically secure — it needs only to provide fair
distribution across the active peer set to ensure convergence.

---

## 7. Catalogue Synchronisation

### 7.1. Digest Computation

A catalogue digest is computed as follows:

1. Collect all loaded cartridge entries as strings of the form
   `"{name}:{version}:{hash}"`.
2. Sort the entries lexicographically.
3. Concatenate the sorted entries with newline separators.
4. Compute the SHA-256 hash of the resulting string.

The digest is a 32-byte value. Implementations MUST support catalogues
of up to 128 cartridge entries.

### 7.2. Synchronisation Trigger

Catalogue synchronisation is triggered when:

- Two peers exchange digests (via handshake or gossip round) and the
  digests differ.

### 7.3. Synchronisation Scope

Synchronisation exchanges *metadata only*:

- Cartridge name (string)
- Cartridge version (string, semver)
- Cartridge content hash (SHA-256 hex string)
- Cartridge tier (e.g. "teranga", "shield", "ayo")
- Protocol columns supported (e.g. "mcp", "lsp", "dap", "bsp")

Synchronisation MUST NOT transfer:

- Cartridge binaries (.so, .dll, .dylib files)
- Cartridge source code
- User data or configuration
- Authentication credentials

### 7.4. Convergence

Under stable network conditions, the gossip protocol ensures eventual
convergence of catalogue views across all federated nodes. The expected
convergence time for a change to propagate to all N nodes is
O(log N) gossip rounds, assuming a fanout of 3.

---

## 8. Security Considerations

### 8.1. Auto-SDP Zero-Trust Perimeter

The Umoja protocol integrates a Software Defined Perimeter (Auto-SDP)
layer that enforces zero-trust principles at the transport level:

- All inbound federation traffic is processed by the SDP layer before
  reaching the gossip protocol.
- Peers MUST be on the allow-list to send gossip or heartbeat traffic.
  Unknown peers are permitted only to send DISCOVER and
  HANDSHAKE_INIT packets.
- Open mode (allowing unauthenticated peers) is available for initial
  seed bootstrapping but SHOULD be disabled once a federation is
  established.

### 8.2. Authentication and Banning

- Peers that fail authentication (invalid X25519 key exchange,
  mismatched node IDs, or tampered digests) increment a failure counter.
- After `ban-threshold` (default: 5) consecutive authentication
  failures, the peer is automatically banned for `ban-duration`
  (default: 300 seconds).
- Banned peers are tracked by node ID. All packets from banned peers
  are silently dropped.
- The ban list supports up to 64 entries; when full, the oldest ban
  entry is evicted.

### 8.3. Rate Limiting

- Per-peer rate limiting is enforced by the SDP layer (default: 100
  requests per second).
- Peers exceeding the rate limit transition to `rate_limited` policy
  and excess packets are dropped.
- Rate-limited peers are not banned but MAY be banned if rate
  violations persist.

### 8.4. Hash Attestation

- Catalogue digests are computed locally from the node's own loaded
  cartridges. A node MUST NOT accept a digest from a peer as its own
  catalogue state.
- Digest comparison is used for synchronisation decisions only; a
  mismatched digest does not constitute an attack. However, a peer that
  consistently reports different digests in rapid succession (digest
  thrashing) SHOULD be flagged for investigation.

### 8.5. Transport Security

- Encrypted mode (X25519 + ChaCha20-Poly1305) provides confidentiality
  and integrity for all gossip traffic. Note that the current design
  uses long-lived identity keypairs without ephemeral key exchange,
  which does not provide forward secrecy. Future revisions of this
  protocol SHOULD incorporate ephemeral ECDH or a full QUIC handshake
  to achieve forward secrecy.
- The shared secret derived from X25519 SHOULD be processed through
  HKDF [RFC 5869] before use as a ChaCha20-Poly1305 key, rather than
  used directly. The reference implementation currently uses the raw
  shared secret; this is a known limitation.
- Implementations MUST track received nonces per peer to prevent replay
  attacks. Nonces SHOULD be counter-based (monotonically increasing)
  rather than random to enable efficient duplicate detection.
- UDP fallback mode provides none of these properties and MUST NOT be
  used in production.
- Implementations SHOULD default to encrypted mode and require explicit
  configuration to enable UDP fallback.

### 8.6. No Code Execution

The protocol exchanges metadata only. Implementations MUST NOT execute,
load, or interpret any data received via the federation protocol as
code. Cartridge installation from federated peers requires an
out-of-band mechanism with its own authentication and integrity
verification.

---

## 9. IANA Considerations

### 9.1. Port Number Registration

This document requests registration of the following port number:

| Service Name | Port Number | Transport Protocol | Description |
|-------------|-------------|-------------------|-------------|
| umoja-fed   | 9999        | UDP               | Umoja Federation Protocol |

**Note:** Port 9999 is currently assigned to the "distinct" service in
the IANA Service Name and Transport Protocol Port Number Registry. The
reference implementation uses 9999 as a configurable default. A formal
port allocation from the User Ports range (1024-49151) will be
requested if this protocol progresses beyond Experimental status.
Implementations MUST support configurable port assignment.

### 9.2. IPv6 Multicast Address

This document requests allocation of the following IPv6 multicast
address from the Link-Local Scope Multicast Addresses registry:

| Address    | Description                          |
|------------|--------------------------------------|
| ff02::b04  | Umoja Federation Discovery (link-local) |

---

## 10. References

### 10.1. Normative References

- **[RFC 2119]** Bradner, S., "Key words for use in RFCs to Indicate
  Requirement Levels", BCP 14, RFC 2119, DOI 10.17487/RFC2119,
  March 1997.

- **[RFC 8174]** Leiba, B., "Ambiguity of Uppercase vs Lowercase in
  RFC 2119 Key Words", BCP 14, RFC 8174, DOI 10.17487/RFC8174,
  May 2017.

- **[RFC 9000]** Iyengar, J., Ed. and M. Thomson, Ed., "QUIC: A
  UDP-Based Multiplexed and Secure Transport", RFC 9000,
  DOI 10.17487/RFC9000, May 2021.

- **[RFC 7748]** Langley, A., Hamburg, M., and S. Turner, "Elliptic
  Curves for Security", RFC 7748, DOI 10.17487/RFC7748, January 2016.

- **[RFC 8439]** Nir, Y. and A. Langley, "ChaCha20 and Poly1305 for
  IETF Protocols", RFC 8439, DOI 10.17487/RFC8439, June 2018.

- **[RFC 5869]** Krawczyk, H. and P. Eronen, "HMAC-based
  Extract-and-Expand Key Derivation Function (HKDF)", RFC 5869,
  DOI 10.17487/RFC5869, May 2010.

### 10.2. Informative References

- **[draft-cui-ai-agent-discovery-invocation-00]** Cui, Y., et al.,
  "AI Agent Discovery and Invocation", Internet-Draft, 2025.

- **[draft-narajala-ans-00]** Narajala, S., et al., "Agent Naming
  Service", Internet-Draft, 2025.

- **[draft-mp-agntcy-ads]** Petrovic, M., et al., "Agent Discovery
  Service", Internet-Draft, 2025.

- **[SWIM]** Das, A., Gupta, I., and A. Motivala, "SWIM: Scalable
  Weakly-consistent Infection-style Process Group Membership Protocol",
  Proceedings of the International Conference on Dependable Systems and
  Networks, 2002.

---

## Appendix A: Packet Format Diagrams

### A.1. Cleartext Packet Header

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|0| Pkt Type(7) |         Payload Length        |               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+               |
|                                                               |
|                     Payload (variable)                        |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Bit 0 = 0 indicates cleartext mode.

### A.2. QUIC-Mode Packet Header

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|1| Pkt Type(7) |         Payload Length        |               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+               |
|                                                               |
|                       Nonce (12 bytes)                        |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                Encrypted Payload (variable)                   |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                   Auth Tag (16 bytes)                         |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

Bit 0 = 1 indicates QUIC/encrypted mode.

### A.3. DISCOVER Packet Payload

```
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Node ID Length (1 byte)     |                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                               |
|                    Node ID (up to 64 bytes)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         Listen Port           |                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### A.4. GOSSIP_DIGEST Packet Payload

```
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
|                 Catalogue Digest (32 bytes)                   |
|                           SHA-256                             |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Gossip Round Number                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

---

## Appendix B: Example Message Flows

### B.1. New Node Joining via Seed

```
New Node                    Seed Node
   │                           │
   │── DISCOVER ──────────────►│
   │   (node_id, port)         │
   │                           │
   │◄── DISCOVER_REPLY ───────│
   │   (seed_id, seed_port,    │
   │    known_peers[])         │
   │                           │
   │── HANDSHAKE_INIT ───────►│
   │   (public_key, node_id)   │
   │                           │
   │◄── HANDSHAKE_REPLY ─────│
   │   (public_key, node_id,   │
   │    catalogue_digest)      │
   │                           │
   │── GOSSIP_DIGEST ────────►│  (encrypted, QUIC mode)
   │   (catalogue_digest)      │
   │                           │
   │◄── GOSSIP_DIGEST_REPLY ──│  (encrypted, QUIC mode)
   │   (peer_digest,           │
   │    diff_entries[])        │
   │                           │
   │    ... heartbeats ...     │
   │──── HEARTBEAT ──────────►│
   │◄─── HEARTBEAT ──────────│
```

### B.2. Catalogue Change Propagation (3 Nodes)

```
Time  Node A            Node B            Node C
 t=0  loads cartridge
      recomputes digest
 t=5  gossip round:
      selects B
      ── DIGEST ──►
                      compares digests
                      (differ!)
      ◄── REPLY ────
      A knows B knows
 t=10                 gossip round:
                      selects C
                      ── DIGEST ──────►
                                        compares digests
                                        (differ!)
                      ◄── REPLY ──────
                      B knows C knows

All three nodes now aware of the new cartridge (2 rounds, O(log N)).
```

---

## Author's Address

Jonathan D.A. Jewell
hyperpolymath
Email: j.d.a.jewell@open.ac.uk
URI: https://github.com/hyperpolymath
