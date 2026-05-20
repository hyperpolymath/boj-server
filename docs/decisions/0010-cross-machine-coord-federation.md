<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# 10. Cross-machine coord federation — DID identity, ML-KEM exchange, federated quarantine

Date: 2026-05-20

## Status

Proposed (RFC — implementation tracked in epic #87 item 3)

## Context

`local-coord-mcp` provides multi-agent coordination over a loopback bus (`127.0.0.1:7745`). Within one machine this works well — peer registration, typed envelopes, claim/heartbeat/watchdog, master-supervised quarantine. Cross-machine coordination is the major missing axis.

The v0.1.0 changelog mentions "Umoja federation with QUIC+UDP gossip protocol (40 tests)". Status today is unclear: the gossip code exists in places but isn't wired into the active coord cartridge, and there's no documented identity model, no key-exchange story, and no federated quarantine semantics. Cross-machine multi-agent is effectively unsupported.

Why this matters now:

- BoJ's three trust tiers and master/journeyman/apprentice supervision are the *differentiated* part of the architecture. They become much more useful when "master" can be on a different machine than "apprentice" (a security boundary).
- The sandbox cartridge (ADR-0009) is machine-local by construction; meaningful agent-cluster work spans multiple machines, each with its own sandboxes.
- EXHIBIT-B (Quantum-Safe Provenance) and `stapeln.toml`'s ML-DSA-87 signing already commit BoJ to a post-quantum posture. Federation is the natural place to make this load-bearing on the wire, not just in artefacts.
- ADR-0002 (BoJ-only MCP) means agents on different machines cannot federate via "two separate MCPs talking" — federation has to be a property of one cartridge family (coord-mcp) spanning machines.

## Decision

Promote `local-coord-mcp` from loopback-only to **federated coord-mcp**, with three architectural pillars:

### 1. DID-based peer identity

Replace today's ad-hoc peer IDs (`<kind>-<4hex>[@<context>]`) with **Decentralised Identifiers** (DIDs) per W3C DID-Core 1.0:

```
did:boj:peer:<base32-encoded-ML-DSA-public-key>
```

- The `boj` method is a new method registered in the estate's DID registry repo
- Peer keypair generation is local (ML-DSA-87 per estate standard); private key never leaves the machine
- DIDs are resolved via the same `cartridge-index` infrastructure used in ADR-0008 (federated, content-addressed)
- Multiple peers on one machine share the machine's identity but have distinct peer IDs *under* that DID (`did:boj:peer:.../peer-id/<n>`)
- The existing `coord_register` token stays as the *session* token; the DID is the *identity*

### 2. ML-KEM key exchange + encrypted envelopes

When peer A (on machine α) wants to talk to peer B (on machine β):

1. **Discovery** — A queries the federated peer registry (peer publishes its DID + machine endpoint via DNS-SD or static config) to resolve B's transport URL + KEM public key
2. **Handshake** — A and B perform ML-KEM-1024 ephemeral key exchange (estate post-quantum standard), deriving a session AEAD key
3. **Signed-and-encrypted envelopes** — coord messages between A and B are wrapped in (ML-DSA-87 signature by sender) → (ChaCha20-Poly1305 AEAD with the derived session key) → wire bytes
4. **Transport** — HTTPS POST to B's coord federation endpoint (`/coord/federated/inbox`), or QUIC if both peers advertise it

Envelopes are otherwise the same Nickel-validated A2ML envelopes the loopback bus uses today. Federation is a transport + crypto + identity layer; the *semantics* don't change.

### 3. Federated quarantine

The master-approval flow already exists for tier-2+ operations within a machine. Federating it requires three new behaviours:

**a. Master visibility across machines**

A single master peer can be on any machine in the federation. Peers on other machines route their quarantine entries to that master's machine. The master sees a unified queue via `coord_review` regardless of source.

**b. Master-uniqueness invariant federation-wide**

Proof obligation **P-04** (master uniqueness) currently holds within one machine. The federated version requires consensus: at most one peer in the federation holds the `master` role at any time. Mechanism: lightweight HOTSTUFF-style election with the federation's DID set; the elected master broadcasts a signed "I-am-master" attestation on every coord heartbeat, and peers reject impostor master messages.

**c. Cross-machine handoff**

`coord_transfer_master` already supports same-machine handoff. Federated version routes the handoff envelope cross-machine and verifies the successor's DID is in the federation's roster before the handoff completes.

### Topology variants

**Mesh** (default): every peer talks to every other peer. Suitable for small federations (≤16 peers). No coordinator.

**Hub-and-spoke**: one "rendezvous" peer holds the master role and routes all cross-machine traffic. Simpler firewall posture; single point of failure.

**Hub-and-rim** (recommended for production): one rendezvous *machine* (running a dedicated `coord-mcp` instance with no LLM-peer attached) routes the federation. Master peer can move between machines but the routing endpoint is stable. Failure of any LLM-peer machine doesn't take down the federation.

Operators choose via `COORD_FEDERATION_TOPOLOGY=mesh|hub|hub-and-rim`.

### Trust posture

A federation is **opt-in per machine**:

- Default: `COORD_FEDERATED=false` (current loopback-only behaviour)
- Enabled: `COORD_FEDERATED=true` + `COORD_FEDERATION_ROSTER=<path-to-DID-set.a2ml>`
- The roster is a signed file listing the DIDs of all participating machines, plus the master-election rules
- A peer never accepts envelopes from a DID not in the roster

## Consequences

### Positive

- **Federation makes the tier model meaningfully secure** — apprentice on one machine, master on another machine = real security boundary, not just role labelling.
- **Post-quantum on the wire** — ML-KEM + ML-DSA-87 brings the wire surface to the same posture as the artefact-signing surface. Aligns EXHIBIT-B end-to-end.
- **DID identity is decentralised** — no central authority issues peer IDs; private keys never leave the machine. Aligns with BoJ's sovereignty branding.
- **Existing semantics preserved** — A2ML envelopes, Nickel contracts, watchdog TTLs all unchanged. Federation is purely a transport + identity layer.
- **Production-grade topology** — hub-and-rim addresses the "what if my master machine goes down" question that mesh and hub don't.
- **Composable with sandbox-mcp** — federated peers can each run their own sandboxes; the federation message bus coordinates which peer does what, even though sandboxes themselves remain machine-local.
- **Reuses estate infrastructure** — `cartridge-index` (ADR-0008) for DID resolution, ML-DSA-87 / ML-KEM standards (EXHIBIT-B) for crypto. No new infrastructure repos needed.

### Negative

- **Complexity escalation** — federation is the heaviest item in epic #87. Multi-week implementation; likely the longest-running campaign.
- **Crypto correctness surface** — ML-KEM handshake + AEAD framing + signature verification has many failure modes. Mitigation: use well-reviewed libraries (libsodium-style high-level constructions); proof obligations on the crypto handshake state machine.
- **Latency** — cross-machine RTT becomes part of the coord critical path. Mitigation: keep claim/heartbeat *machine-local*; only quarantine review + master attestation cross machines.
- **Roster management** — operators must maintain the signed `COORD_FEDERATION_ROSTER` file. Mitigation: tooling (`coord_federation_add_peer` / `coord_federation_remove_peer` tools that re-sign the roster atomically).
- **NAT/firewall traversal** — hub-and-rim avoids most of this; mesh has full N×N connectivity requirements. Document this in operator guide; recommend hub-and-rim for any deployment beyond a developer's laptop.

## Non-goals

- **Not building a generic federated agent framework** — this is BoJ's coord cartridge growing legs, not a competitor to libp2p or similar. Borrow ideas; don't reimplement.
- **Not supporting plaintext federation** — there is no `COORD_FEDERATION_INSECURE=true` flag. Federation without crypto is not federation.
- **Not making federation transparent to existing prompts** — the `convene-cluster` prompt (PR #89) implicitly assumed loopback; federated version surfaces the federation roster + topology so the LLM can reason about which machine to dispatch to.
- **Not federating sandbox handles** — see ADR-0009 explicit constraint: sandbox lifetime is machine-bound. Federation coordinates *which peer runs a sandbox*, not *passing live sandbox handles across machines*.
- **Not implementing Byzantine fault tolerance** — federation assumes the roster's signing keys are honest. Compromised-key scenarios require roster rotation, not BFT consensus.

## Open questions

1. **DID method registration** — register `did:boj:` in the W3C DID method registry, or stay in a `private:` namespace? Recommend register; the estate is open-source and the method is novel enough to be reviewable.

2. **Roster mutability** — when a new peer joins, every existing peer needs the updated roster. Manual push? Gossip? Recommend manual signed roster updates pushed by current master to all peers, ratified by signature verification at receipt.

3. **What if the master-election partitions** — two halves of a network partition each elect a master. Recommend split-brain detection on partition heal: the higher-attestation-epoch master wins; the other voluntarily demotes. Lose all in-flight quarantine work in the losing partition.

4. **Cross-machine `coord_send_gated` quarantine retention** — quarantine queue is currently in-memory on the master's machine. Cross-machine durability requires either (a) durable queue on every machine that mirrors the master's queue, or (b) the master persists to durable storage local to it. Recommend (b) for v1; revisit if master-machine failure recovery is a hard requirement.

5. **Performance ceiling** — the design comfortably handles ≤16 peers across ≤8 machines. Beyond that, mesh becomes O(N²); hub-and-rim scales further but eventually needs sharding. Document the ceiling explicitly; revisit if it bites.

6. **Bootstrap with no DNS-SD** — pure static config (`COORD_FEDERATION_ROSTER` lists every peer's endpoint) works but isn't auto-discoverable. Recommend ship both modes; let operator choose.

## Implementation sketch

When this RFC is accepted (multi-stage):

**Stage 1 — DID identity** (~1 week)
- Add `cartridges/local-coord-mcp/abi/LocalCoord/DID.idr` with method definition
- Generate ML-DSA-87 keypair on first `coord_register`; persist to `~/.boj/coord/identity.json`
- New tool `coord_did` returns the local peer's DID
- Loopback-only; no federation yet

**Stage 2 — ML-KEM handshake** (~1 week)
- Add `cartridges/local-coord-mcp/abi/LocalCoord/Handshake.idr`
- ML-KEM-1024 keypair generated alongside ML-DSA-87 keypair
- New private state-machine ABI; not tool-exposed yet

**Stage 3 — Encrypted wire format** (~1 week)
- Federated envelope wrap: `(signature, AEAD(plaintext, session_key))`
- New A2ML schema `coord-federated-envelope.ncl` (Nickel)
- Round-trip tests; no network yet

**Stage 4 — Network transport** (~1 week)
- HTTPS POST endpoint at `/coord/federated/inbox`
- Optional QUIC transport behind feature flag
- Static roster only; no discovery

**Stage 5 — Federated master election + quarantine** (~1 week)
- HOTSTUFF-style election among roster
- Quarantine routing to master's machine
- Federated `coord_review` / `coord_approve` / `coord_reject`

**Stage 6 — Hub-and-rim topology + operator tooling** (~1 week)
- `coord-rendezvous-mcp` cartridge for the rim role
- Roster-management tooling
- Federation-aware prompts (replace loopback assumptions in `convene-cluster`)

Total: ~6 weeks of focused work. Stages 1–3 are foundational; 4–6 progressively expose the federation to users.

## Linked

- EXHIBIT-B (Quantum-Safe Provenance) — establishes ML-DSA-87, applied here.
- ADR-0002 (BoJ-only MCP) — federation must be in-cartridge, not in-MCP-server.
- ADR-0007 (trust-tier policy DSL) — federation roster is a policy artefact.
- ADR-0008 (cartridge marketplace) — DID resolution shares infrastructure with cartridge-index.
- ADR-0009 (sandbox cartridge) — sandboxes stay machine-local; federation coordinates which peer runs which sandbox.
- W3C DID Core 1.0 — identity model.
- NIST FIPS 203 (ML-KEM) and FIPS 204 (ML-DSA) — crypto primitives.
- Epic #87 item 3 (this).
