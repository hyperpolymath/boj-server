<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# 16. mTLS + ed25519 federation stop-gap — spike

Date: 2026-05-24

## Status

Accepted (2026-05-24) — chosen over ADR-0015 because it closes the
more user-visible survey gap (Ruflo as the only comparator with a
cross-host story) and is additive: loopback bus and Idris2-verified
intra-host ABI stay untouched. Positioned as the v1 transport;
ADR-0010 (DID + ML-DSA-87 + ML-KEM-1024 + federated quarantine)
remains the v2 upgrade path.

**Implementation plan:** phased rollout, each phase its own PR off
`main` after this ADR lands.

| Phase | Scope | Estimated |
|---|---|---|
| 1 | Identity foundation — ed25519 keypair, pubkey export, `known_peers.toml` parser, `coord-tui --print-pubkey` flag. No transport. | ~1 day |
| 2 | Envelope sign/verify on the loopback bus (round-trip validation before any wire work). | ~1 day |
| 3 | TLS listener on `:7746` + mTLS handshake gated by `known_peers.toml`. | ~1-2 days |
| 4 | New `coord_add_peer` / `coord_remove_peer` / `coord_list_remote_peers` tools — bridge + cartridge.json sync. | ~0.5 day |
| 5 | Idris2 `Federation.idr` — envelope-boundary signature soundness obligation. | ~1 day |
| 6 | Tests — two-instance round-trip, signature tampering, replay protection. | ~0.5 day |

## Context

The multi-agent MCP survey identified `ruvnet/ruflo` as the only
comparator shipping a real cross-host story (mTLS + ed25519 federation
across machines). `local-coord-mcp` is currently localhost-only
(`127.0.0.1:7745`) — closing this gap is one of the two outstanding
items from PR #143's spike.

ADR-0010 already proposes the *ambitious* answer: DID-based identity,
ML-DSA-87 signing, ML-KEM-1024 key exchange, federated quarantine. It
sits at "Proposed (RFC)" status, tracked under epic #87 item 3, and is
a substantial cross-cartridge build effort.

This spike evaluates a deliberately **smaller** stop-gap: ship
Ruflo-equivalent cross-host federation using mTLS + ed25519 *now*,
without blocking on the post-quantum work in ADR-0010. The two are
compatible: this becomes the v1 transport, ADR-0010 becomes the v2
upgrade path.

## What the change does

1. **Transport.** Add a TLS-terminating endpoint alongside the loopback
   bus — `https://<host>:7746/coord/federated/inbox` for inbound
   federated envelopes. Loopback bus (`:7745`) stays the default for
   intra-machine traffic and is untouched.
2. **Identity.** Each peer generates an ed25519 keypair on first run
   (stored under `~/.cache/coord-tui/peer.key`). The public key is the
   peer's federated identity; the private key signs outbound envelopes.
   No DID method, no PKI hierarchy — leaf-only trust.
3. **Peer trust.** A new file `~/.config/coord-tui/known_peers.toml`
   maps peer-id → `{host, port, pubkey}`. Federation only works between
   peers that have explicitly added each other (manual key exchange via
   `coord-tui --print-pubkey` and a shared channel). No discovery; no
   registry.
4. **mTLS.** Both ends of the federated link present client certs
   derived from their ed25519 identity keys (SPKI-pinned, not
   CA-signed). Connection fails closed if the presented pubkey doesn't
   match `known_peers.toml`.
5. **Envelope wrapping.** Outbound coord messages destined for a remote
   peer are signed (ed25519 over the canonical envelope bytes), wrapped
   in `{from, to, signature, payload}`, sent over the mTLS connection.
   Receiver verifies signature against `known_peers.toml`, then injects
   into the local bus as if it had arrived locally.
6. **New tools.** `coord_add_peer(peer_id, host, port, pubkey)`,
   `coord_remove_peer(peer_id)`, `coord_list_remote_peers()`. No tool
   schema change to the existing `coord_send` / `coord_claim_task`
   surface — federation is transport-layer.

## Cost

| Surface | Work |
|---|---|
| Zig adapter | TLS listener (use `std.crypto.tls`), ed25519 sign/verify (`std.crypto.sign.Ed25519` — already available), known_peers parser, envelope wrap/unwrap. ~400-600 LOC. |
| Idris2 ABI | New `Federation.idr` — but only proof obligations on the *envelope* boundary (signature verification soundness), not on the transport. ~150 lines; reuses existing `SafeHTTP` patterns. Class (J) believe_me may be unavoidable for `std.crypto.tls` opaque primitives — same axiom posture as the existing `Char`/`String` primitives. |
| Bridge | New 3 `coord_*` tool entries in `tools.js` + cartridge.json; dispatcher routes them to the backend. No envelope-shape changes. |
| coord-tui | `--print-pubkey` flag, `~/.config/coord-tui/known_peers.toml` reader, optional `coord-add-peer` shell helper. |
| Tests | Round-trip test on two backend instances on different ports; signature-tampering rejection test; replay-protection (envelope timestamp + nonce). |

Estimated: 4-6 working days end-to-end.

## Benefit

- Closes the survey's "cross-host transport" gap directly: matches
  Ruflo's posture, doesn't claim more.
- Additive — the existing loopback bus and Idris2-verified intra-host
  ABI are untouched. No proof regression.
- Sets up ADR-0010 as a clean v2 upgrade (swap ed25519→ML-DSA-87,
  add ML-KEM, add DID resolution) once that work is prioritised.
  Wire format is the same shape; only the cryptographic primitives
  change.
- Real user-visible feature — agents on Jonathan's workstation can
  coordinate with agents on a build server, a sandbox VM, or a
  teammate's machine.

## Risks / open questions

- **Trust bootstrap is manual.** Exchanging pubkeys via a shared
  channel is the right answer for a v1 (it's how SSH known_hosts
  works), but it does mean federation has a per-peer setup cost. ADR-
  0010's DID + cartridge-index resolution removes this; v1 doesn't.
- **No federated quarantine.** Tier-2+ envelopes from a remote peer
  hit the *local* master for review — no upstream supervision model.
  This is a feature gap relative to ADR-0010, not a bug, but worth
  naming.
- **Crypto agility.** ed25519 in a post-quantum world has a finite
  shelf life. Estate standards already commit to ML-DSA-87. This
  spike's stop-gap framing is honest about that: v1 lasts until ADR-
  0010 lands, not forever. CHANGELOG and README should say so.
- **Idris2 transport-layer proofs.** TLS internals are opaque to the
  Idris2 backend-assurance harness — same axiomatisation posture as
  the existing 5 `believe_me` sites. Net new principled assumption,
  not a regression.

## Verdict

Smaller scope than ADR-0015, lower architectural risk than ADR-0010,
and directly closes the only survey gap where `local-coord-mcp`
clearly trails a comparator. The "this is explicitly a stop-gap"
framing keeps the door open for ADR-0010 without making it a
blocker.

**Recommendation:** Prefer this over ADR-0015 if the goal is "ship a
visible new capability that the survey identified as missing".
Combine with ADR-0015 only if file-locks are a stated user need;
otherwise ADR-0015 is gold-plating relative to the survey's actual
findings.

## Out of scope

- DID identity (ADR-0010, v2 upgrade).
- Post-quantum crypto (ADR-0010, v2 upgrade).
- Discovery / registry (deliberate — manual known_peers keeps the
  trust story legible).
- Federated quarantine semantics (would land alongside DID work).
- Wire format negotiation for v1↔v2 transition — addressed when
  ADR-0010 implementation starts.
