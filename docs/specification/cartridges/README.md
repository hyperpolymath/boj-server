<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->
# BoJ Cartridge Specification

**Normative specification for BoJ cartridges — what a cartridge IS, how it is
structured, and what invariants it must satisfy.**

For the cartridge specification itself (what a cartridge IS), see this document.
For the tooling that mints, provisions, configures, and harnesses cartridges,
see [../cartridge-tools/README.md](../cartridge-tools/README.md).

---

## Normative Language

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**,
**SHOULD**, **SHOULD NOT**, **RECOMMENDED**, **MAY**, and **OPTIONAL** in this
document are to be interpreted as described in RFC 2119.

---

## Table of Contents

1. [Preamble and Scope](#1-preamble-and-scope)
2. [Axis 1 — ProtocolType (columns)](#2-axis-1--protocoltype-columns)
3. [Axis 2 — CapabilityDomain (rows)](#3-axis-2--capabilitydomain-rows)
4. [The 2D Capability Matrix](#4-the-2d-capability-matrix)
5. [Axis 3 — HAT (Hardware Attached on Top)](#5-axis-3--hat-hardware-attached-on-top)
6. [Cartridge Manifest (Nickel)](#6-cartridge-manifest-nickel)
7. [Surface Ephemerality — Three-Axis Transport Model](#7-surface-ephemerality--three-axis-transport-model)
8. [Transaction-Based Ephemerality (Time Axis)](#8-transaction-based-ephemerality-time-axis)
9. [Transport Preference Ordering and Security Grades](#9-transport-preference-ordering-and-security-grades)
10. [Transport Provenance](#10-transport-provenance)
11. [Reference Implementation Pattern](#11-reference-implementation-pattern)
12. [Relationship to Cartridge Tools](#12-relationship-to-cartridge-tools)

---

## 1. Preamble and Scope

### 1.1 What a Cartridge Is

A **cartridge** is a formally verified, swappable capability module for the BoJ
(Bundle of Joy) server. Each cartridge occupies one or more cells in a
two-dimensional capability matrix whose axes are:

- **ProtocolType** (the columns) — *how* callers talk to the server.
- **CapabilityDomain** (the rows) — *what* the server does.

An optional third axis, **HAT** (Hardware Attached on Top), bridges a verified
cartridge to unverified external tools. HAT presence does not alter the formal
safety properties of the cartridge.

The matrix is **sparse**: not every (ProtocolType, CapabilityDomain) cell needs
to be occupied. Unoccupied cells are simply absent from the catalogue.

### 1.2 Formal Foundation

The authoritative formal definition of a cartridge is in Idris 2:

- `src/abi/Boj/Catalogue.idr` — the `Cartridge` record, lifecycle, `IsUnbreakable`
  proof, and catalogue query functions.
- `src/abi/Boj/Protocol.idr` — the `ProtocolType` enumeration.
- `src/abi/Boj/Domain.idr` — the `CapabilityDomain` enumeration.

This document is a **normative prose projection** of those definitions. If
there is ever a discrepancy between this document and the Idris 2 source, the
Idris 2 source is authoritative.

### 1.3 Scope of This Document

This specification normatively defines:

- The ProtocolType and CapabilityDomain axes and their allowed values.
- The 2D capability matrix structure, sparse-cell model, lifecycle, proof
  requirement, menu tier, and hash attestation.
- The HAT third-dimension model and the four bridge types.
- The Nickel cartridge manifest schema.
- The three-axis surface ephemerality model.
- Transaction-based ephemerality.
- Transport preference ordering and security grades.
- Transport provenance tracking.
- The reference implementation pattern.

This specification does **NOT** cover:

- How cartridges are minted, provisioned, configured, or connected to panll
  panels. Those are the responsibility of the cartridge-tools suite; see
  [../cartridge-tools/README.md](../cartridge-tools/README.md).
- The backend (third dimension for community extension) axis; see
  [../../EXTENSIBILITY.md](../../EXTENSIBILITY.md).
- Federation, gossip protocol, or node topology.
- The BoJ REST/gRPC API surface.

---

## 2. Axis 1 — ProtocolType (Columns)

ProtocolType defines **how** a caller communicates with a cartridge. It forms
the **columns** of the 2D matrix.

Every cartridge MUST declare at least one ProtocolType in its `protocols` list.
A cartridge MAY declare multiple protocols; each (protocol, domain) pair
constitutes one matrix cell.

| Value | Int | Description | Primary transport |
|-------|-----|-------------|-------------------|
| `MCP` | 1 | Model Context Protocol — AI tool integration (stdio, SSE, WebSocket) | stdio / SSE |
| `LSP` | 2 | Language Server Protocol — editor/IDE integration | stdio / TCP |
| `DAP` | 3 | Debug Adapter Protocol — debugger integration | stdio / TCP |
| `BSP` | 4 | Build Server Protocol — build system integration | stdio / TCP |
| `NeSy` | 5 | Neurosymbolic Protocol — proven-neurosym, Hypatia integration | internal |
| `Agentic` | 6 | Agentic Protocol — proven-agentic, OODA loop orchestration | internal |
| `Fleet` | 7 | Fleet Protocol — gitbot-fleet orchestration | internal |
| `GRPC` | 8 | gRPC — high-performance binary RPC | TCP (TLS) |
| `REST` | 9 | REST/HTTP — universal fallback | TCP (HTTP/1.1 or HTTP/2) |

The integer encoding is the C-ABI wire value used by the Zig FFI layer
(`protocolToInt` / `intToProtocol` in `Boj.Protocol`).

---

## 3. Axis 2 — CapabilityDomain (Rows)

CapabilityDomain defines **what** a cartridge does. It forms the **rows** of
the 2D matrix.

Every cartridge MUST declare exactly one CapabilityDomain.

| Value | Int | Description |
|-------|-----|-------------|
| `Cloud` | 1 | Cloud provider operations (AWS, GCP, Azure, Cloudflare, etc.) |
| `Container` | 2 | Container management — Podman, OCI image lifecycle |
| `Database` | 3 | Database operations — SQL, NoSQL, VeriSimDB |
| `K8s` | 4 | Kubernetes orchestration — workloads, namespaces, CRDs |
| `Git` | 5 | Git/VCS operations — GitHub, GitLab, Bitbucket |
| `Secrets` | 6 | Secret management — Vault, SOPS, sealed-secrets |
| `Queues` | 7 | Message queues — NATS, RabbitMQ, Kafka |
| `IaC` | 8 | Infrastructure as Code — Terraform, Pulumi, Nix, Guix |
| `Observe` | 9 | Observability — metrics, logs, distributed traces |
| `SSG` | 10 | Static site generation — Jekyll, Hugo, Zola |
| `Proof` | 11 | Formal proof assistants — Idris2, Lean4, Coq/Rocq |
| `FleetDom` | 12 | Gitbot fleet domain — rhodibot, echidnabot, sustainabot, etc. |
| `NeSyDom` | 13 | Neurosymbolic reasoning — Hypatia, ECHIDNA |
| `Agent` | 14 | Autonomous AI agents — agentic-workflows, autonomous-fleet |
| `Lsp` | 15 | Language Server Protocol domain (complementary to the LSP protocol axis) |
| `Dap` | 16 | Debug Adapter Protocol domain |
| `Bsp` | 17 | Build Server Protocol domain |
| `CodeIntel` | 18 | Code intelligence — semantic search, knowledge graph, Graph RAG |

The integer encoding is the C-ABI wire value used by the Zig FFI layer
(`domainToInt` / `intToDomain` in `Boj.Domain`).

---

## 4. The 2D Capability Matrix

### 4.1 Sparse-Cell Model

The matrix is indexed by `(ProtocolType, CapabilityDomain)`. A cell is
**occupied** if at least one cartridge in the catalogue claims that (protocol,
domain) pair. A cell is **empty** if no cartridge covers it; empty cells carry
no meaning and MUST NOT be treated as errors.

```
               Protocol (column)
             ┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬──────┬──────┐
  Domain     │ MCP │ LSP │ DAP │ BSP │NeSy │Agnt │Flt  │ gRPC │ REST │
  (row)      ├─────┼─────┼─────┼─────┼─────┼─────┼─────┼──────┼──────┤
  Cloud      │  ██ │     │     │     │     │     │     │  ██  │  ██  │
  Container  │  ██ │     │     │     │     │     │     │  ██  │  ██  │
  Database   │  ██ │     │     │     │     │     │     │  ██  │  ██  │
  Git        │  ██ │     │     │     │     │     │  ██ │  ██  │  ██  │
  ...        │     │     │     │     │     │     │     │      │      │
             └─────┴─────┴─────┴─────┴─────┴─────┴─────┴──────┴──────┘
             (filled cells are illustrative; actual catalogue may differ)
```

A single cartridge with `protocols = [MCP, GRPC, REST]` occupies **three cells**
in the same domain row.

### 4.2 CartridgeStatus Lifecycle

Every cartridge has a `CartridgeStatus` that governs whether it may be mounted.

```
  Development ──► Ready ──► Deprecated
                    │
                    └──► Faulty
```

| Status | Int | Mountable | Description |
|--------|-----|-----------|-------------|
| `Development` | 0 | No | Under construction; proofs incomplete |
| `Ready` | 1 | Yes | Fully verified; safe to mount |
| `Deprecated` | 2 | No | Scheduled for removal; MUST NOT be mounted by new callers |
| `Faulty` | 3 | No | Broken or compromised; MUST NOT be mounted |

A cartridge MUST be in `Ready` status before the Zig FFI layer will activate it.
This constraint is enforced by the `IsUnbreakable` proof (§4.3).

`Deprecated` cartridges MAY remain mounted for existing callers during a
migration window, but new `lookupCell` calls MUST NOT return them.

### 4.3 IsUnbreakable Proof

The `IsUnbreakable` predicate is the core safety gate:

```idris
data IsUnbreakable : Cartridge -> Type where
  VerifiedReady : (c : Cartridge) ->
                  (status c = Ready) ->
                  IsUnbreakable c
```

A cartridge is **unbreakable** if and only if its status equals `Ready`. The Zig
FFI layer checks this predicate before mounting any cartridge. No cartridge MAY
be executed without a valid `IsUnbreakable` proof.

The proof is **independent** of HAT presence (§5). A cartridge with a HAT
that is currently failing still holds its `IsUnbreakable` proof; the HAT
failure is isolated by the circuit breaker (§5.4), not by revoking the proof.

### 4.4 MenuTier

Every cartridge MUST declare a `MenuTier` that determines where it appears in
the Teranga navigation menu.

| Tier | Description |
|------|-------------|
| `Teranga` | Core cartridges maintained by the BoJ project |
| `Shield` | Privacy and security cartridges (SDP, oDNS, zero-trust) |
| `Ayo` | Community-contributed cartridges (joy of shared work) |

Community extensions MUST use the `Ayo` tier.

### 4.5 Hash Attestation

Every cartridge MUST supply a `binaryHash` field containing the SHA-256 hex
digest of its compiled shared library (`.so` or platform equivalent). Federation
nodes MUST verify this hash before accepting a remotely-supplied cartridge.

An empty `binaryHash` is permissible only for `Development`-status cartridges.
A `Ready`-status cartridge with an empty `binaryHash` MUST be rejected by the
validator.

---

## 5. Axis 3 — HAT (Hardware Attached on Top)

### 5.1 Motivation

The `IsUnbreakable` proof ensures that only verified cartridges can be mounted.
This would be undermined if cartridges could invoke arbitrary external tools
directly — tools such as the Git CLI, Podman, Terraform, or VeriSimDB that
cannot themselves be formally verified.

The **HAT** (Hardware Attached on Top) model resolves this tension. The name is
an analogy with the Raspberry Pi and BeagleBone hardware extension ecosystem:
small, well-defined add-on boards that sit *on top of* the verified platform
without altering its guarantees.

### 5.2 What a HAT Is

A HAT is a bridge script or module that translates a BoJ cartridge invocation
into a real-world tool call:

```
  BoJ Cartridge (verified)  --->  HAT Bridge  --->  External Tool (unverified)
       git-mcp                    git_hat.sh          git CLI
       container-mcp              podman_hat.sh        podman
       ssg-mcp                    zola_hat.sh          zola
       database-mcp               verisimdb_hat.so     VeriSimDB (Library FFI)
```

The HAT is **outside** the BoJ safety perimeter. BoJ makes no formal guarantees
about HAT behaviour. Correctness of the external tool is entirely the HAT
author's responsibility.

A cartridge MAY have zero HATs (it operates entirely within the BoJ perimeter),
one HAT, or multiple HATs serving different external tools.

### 5.3 Four Bridge Types

| Type | When to use | Example |
|------|-------------|---------|
| **CLI wrapper** | HAT invokes a command-line tool and parses its stdout/stderr | `git_hat.sh` → `git` |
| **JSON-RPC stdio** | HAT speaks JSON-RPC 2.0 over stdin/stdout to an existing MCP-compatible server; enables composition with the existing ecosystem | wrapping a third-party MCP server |
| **HTTP API** | HAT calls a REST or GraphQL endpoint on a local or remote service | cloud provider API calls |
| **Library FFI** | HAT links against a native shared library via C ABI; highest performance, zero IPC overhead | `verisimdb_hat.so` → VeriSimDB |

HAT authors MUST document which bridge type their HAT uses. A single HAT MUST
use exactly one bridge type.

### 5.4 Safety Properties and Circuit-Breaker Isolation

The HAT model preserves BoJ's safety invariants:

- **`IsUnbreakable` still holds**: the cartridge's mounting proof is independent
  of HAT presence or HAT health. A cartridge is unbreakable because its *own*
  status is `Ready` — not because its HAT is healthy.
- **Circuit-breaker isolation**: if a HAT call fails (non-zero exit code,
  timeout, malformed output), the per-cartridge circuit breaker trips. The
  cartridge enters a temporarily degraded state; other cartridges are
  unaffected. The circuit breaker resets after a configurable back-off period.
- **Thread safety preserved**: HAT invocations go through the same
  mutex-protected FFI exports as internal operations. Concurrent HAT calls for
  the same cartridge are serialised.
- **Attestation unaffected**: the HAT is not part of the attested binary.
  Federation nodes verify only the BoJ core binary hash; HAT scripts are
  treated as runtime configuration, not as part of the attested surface.

A cartridge MUST NOT bypass the circuit breaker to retry a failing HAT
inline. Retry logic is the responsibility of the caller, not the cartridge.

---

## 6. Cartridge Manifest (Nickel)

### 6.1 Format Decision

The authoritative cartridge manifest format is **Nickel** (`.ncl`). Nickel
manifests are type-checked at validation time, schema-enforced by the cartridge
validator, and consumed by the cartridge-tools suite.

Existing `cartridge.json` files are **legacy** and MUST be migrated to Nickel.
Until migration is complete both formats coexist; the JSON schema at
`https://boj.dev/schemas/cartridge/v1.json` remains the operative validator for
JSON manifests. New cartridges MUST use Nickel.

### 6.2 Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `name` | `String` | Unique cartridge identifier (snake_case) |
| `version` | `String` | SemVer version string (e.g., `"0.1.0"`) |
| `protocol_type` | `List ProtocolType` | One or more protocol axis values |
| `capability_domain` | `CapabilityDomain` | Single domain axis value |
| `menu_tier` | `MenuTier` | `"Teranga"` \| `"Shield"` \| `"Ayo"` |
| `status` | `CartridgeStatus` | `"Development"` \| `"Ready"` \| `"Deprecated"` \| `"Faulty"` |
| `hash_attestation` | `String` | SHA-256 hex digest of the compiled `.so` (empty string ONLY for `Development`) |
| `supported_transports` | `List TransportEntry` | At minimum one entry per protocol_type declared |

A `TransportEntry` has the following shape:

| Subfield | Type | Description |
|----------|------|-------------|
| `name` | `String` | Transport identifier (e.g., `"stdio"`, `"grpc-tls"`, `"rest-http2"`) |
| `security_grade` | `SecurityGrade` | `"A"` \| `"B"` \| `"C"` \| `"D"` — see §9 |
| `provenance` | `String` | Why this transport is present — see §10 |

### 6.3 Example Nickel Manifest

```nickel
# SPDX-License-Identifier: PMPL-1.0-or-later
# git-mcp cartridge manifest (Nickel)
{
  name = "git-mcp",
  version = "0.2.0",
  protocol_type = ["MCP", "GRPC", "REST"],
  capability_domain = "Git",
  menu_tier = "Teranga",
  status = "Ready",
  hash_attestation = "a1b2c3d4e5f6...",   # SHA-256 of libgit_mcp.so

  supported_transports = [
    {
      name = "stdio",
      security_grade = "A",
      provenance = "Required by MCP protocol spec; default AI agent transport"
    },
    {
      name = "grpc-tls",
      security_grade = "A",
      provenance = "High-throughput CI pipeline integration; requested by fleet-bot"
    },
    {
      name = "rest-http2",
      security_grade = "B",
      provenance = "Universal fallback for HTTP clients"
    }
  ],

  hat = {
    enabled = true,
    bridge_type = "cli-wrapper",
    target = "git",
    bridge_script = "hats/git_hat.sh"
  }
}
```

### 6.4 Legacy JSON Shape (Reference)

For migration reference, a legacy `cartridge.json` has this top-level structure:

```json
{
  "$schema": "https://boj.dev/schemas/cartridge/v1.json",
  "spdx": "PMPL-1.0-or-later",
  "name": "aerie-mcp",
  "version": "0.1.0",
  "domain": "infrastructure",
  "tier": "Ayo",
  "protocols": ["MCP", "REST"],
  "tools": [ ... ]
}
```

The Nickel schema extends this with explicit transport, security grade, and
provenance fields. The `tools` array is retained in the Nickel manifest under
an optional `tools` field; it does not affect the matrix position of the cartridge.

---

## 7. Surface Ephemerality — Three-Axis Transport Model

Surface ephemerality is the property that the cartridge's network attack surface
at any moment is the minimal set of transports actually in use — nothing more.

Three sub-axes together define this surface:

### 7.1 `possible_transports` (Manifest Axis)

`possible_transports` is the set of transports a cartridge is **capable of
speaking at all**. It is derived from `supported_transports` in the manifest.

A transport that does not appear in `possible_transports` **MUST NOT** ever be
opened for this cartridge, regardless of caller demand. This is a hard
capability boundary, enforced at manifest validation time.

### 7.2 `preferred_transports` (Ordering Axis)

`preferred_transports` is an **ordered list** of transports from
`possible_transports`, ranked from most preferred (index 0) to least preferred.
Security grade is the primary sort key (§9); the cartridge author MAY override
the ordering for operational reasons, but MUST document the rationale in the
transport's `provenance` field.

When multiple callers hold different active transports simultaneously, BoJ
honours `preferred_transports` when deciding which transport to offer to a new
caller that has not expressed a preference.

### 7.3 `active_transports` (Runtime Axis)

`active_transports` is the **runtime set** of transports currently in active use
by at least one legitimate caller.

**Default-locked semantics**: a transport that is not in `active_transports` is
**entirely locked down** — it is not listening on any port or file descriptor,
not registered in any routing table, not reachable by any means. The absence is
total, not merely rate-limited or authenticated-only.

**On-demand spin-up**: when a legitimate caller requests a transport for a given
(capability, cartridge) pair, BoJ performs an admission check:

```
  1. Is the transport in possible_transports?          (manifest check)
  2. Does the caller's capability token authorise it?  (capability check)
  3. Is the cartridge in Ready status?                 (IsUnbreakable check)
```

All three MUST pass. On success, BoJ opens the transport, adds it to
`active_transports`, and begins serving the caller. On failure, the request is
rejected with a typed error; no transport is opened.

**Drain-down**: when all callers using a transport disconnect or their
capability tokens expire, BoJ MUST drain and close the transport, removing it
from `active_transports`. Drain is complete when no in-flight requests remain
on that transport.

### 7.4 Relationship to BoJ Design Philosophy

Surface ephemerality and transaction-based ephemerality together reconcile the
design tension between "many endpoints" and "reduced attack surface". A cartridge
can declare nine transports in its manifest while exposing zero of them at rest.
Elixir/BEAM concurrency in the BoJ multiplier layer handles many concurrent
heterogeneous calls without requiring transports to remain persistently open.

---

## 8. Transaction-Based Ephemerality (Time Axis)

### 8.1 Ephemeral Capability Tokens

Every capability invocation is scoped to a **single transaction**. A
transaction begins when a caller presents a capability token and issues a
request; it ends when the response is delivered (or the request errors out).

Capability tokens are **bound to one transaction** and are destroyed at
transaction end. They MUST NOT be reused across requests. This means:

- No persistent session state survives between requests. Callers MUST
  re-authenticate (present a fresh token) for every transaction.
- There is no concept of a "logged-in session" at the cartridge level. The
  BoJ infrastructure layer MAY maintain a session abstraction for UX purposes,
  but the cartridge itself sees only individual authenticated transactions.
- Token destruction is synchronous: at transaction end, the token is zeroed
  from memory before the response is written. The token MUST NOT appear in
  logs, traces, or error payloads.

### 8.2 Long-Lived Streams

Some protocols (WebSocket, SSE) maintain a persistent connection that carries
multiple logical messages. BoJ frames these as a sequence of capability-gated
messages:

- Each **message** on a WebSocket or SSE stream is independently capability-gated.
- A stream connection itself is opened with an initial capability token that
  authorises stream establishment.
- Per-message capability gates are evaluated at message dispatch, not at stream
  open. A capability token that was valid at stream-open MAY expire during the
  stream; subsequent messages will be rejected.
- Callers SHOULD refresh their capability token while a stream is open if they
  intend to send further messages. Streams MUST be closed gracefully when the
  caller's capability expires, not abruptly dropped.

### 8.3 Interaction with Surface Ephemerality

Transaction-based ephemerality is the *time axis*; surface ephemerality (§7)
is the *space axis*. Together they ensure:

- At any moment, only the transports demanded by current callers are open (space).
- At any moment, only the capabilities granted by current tokens are exercisable (time).

---

## 9. Transport Preference Ordering and Security Grades

### 9.1 Security Grades

Every transport entry in `supported_transports` MUST carry a security grade.
Grades rank the security properties of the transport channel itself (not the
application-level authentication).

| Grade | Meaning | Examples |
|-------|---------|---------|
| `A` | Mutual TLS or equivalent forward-secrecy; no unauthenticated transport | `grpc-tls` (mTLS), `stdio` (process-local, OS-enforced) |
| `B` | Server-authenticated TLS; client authentication at application layer | `rest-http2` (TLS + JWT), `wss` (WSS + token) |
| `C` | Authenticated but in-transit not encrypted, or encrypted but unauthenticated | `rest-http1` (plaintext + basic auth) |
| `D` | No transport-level security; suitable only for loopback/localhost | `rest-http-local`, `grpc-insecure-local` |

Grade `D` transports MUST only be declared for localhost (`127.0.0.1` / `::1`)
endpoints. A grade `D` transport MUST NOT be opened on a network-reachable
address.

### 9.2 Preference Ordering

`preferred_transports` ranks entries from most preferred (highest security,
lowest latency) to least preferred. BoJ MUST honour this ordering when selecting
a transport on behalf of a caller that has not expressed a preference.

When multiple callers hold different active transports, BoJ:

1. Selects the highest-preference transport for the new caller.
2. If that transport is not yet active, spins it up (§7.3).
3. If the highest-preference transport is unavailable (HAT circuit breaker open,
   port in use), BoJ falls back to the next entry in `preferred_transports`.

BoJ MUST NOT silently downgrade from a grade `A` or `B` transport to a grade
`C` or `D` transport without emitting a warning to the caller.

---

## 10. Transport Provenance

Every entry in `supported_transports` MUST carry a `provenance` string.
Provenance records **why** the transport exists in the manifest — which upstream
requirement, plugin, or caller demanded it.

### 10.1 Purpose

Provenance serves two purposes:

1. **Traceability**: auditors and operators can understand why each transport is
   open, rather than finding unexplained network endpoints.
2. **Clean-up signal**: if the upstream requirement that justified a transport is
   removed, the provenance field identifies the transport as a candidate for
   removal from `supported_transports`.

### 10.2 Interpretation Rules

| Provenance value | Interpretation |
|-----------------|---------------|
| `"Required by <protocol> spec"` | The transport is mandated by the protocol specification; it MUST be present if the protocol is declared |
| `"Requested by <plugin/caller>"` | A specific downstream consumer requires this transport; it MAY be removed if that consumer is decommissioned |
| `"Fallback for <use case>"` | Operational fallback; SHOULD be removed if the primary transport achieves full coverage |
| `"Loopback-only; for <service>"` | Grade-D localhost transport; MUST be scoped to 127.0.0.1/::1 |

Provenance strings are free-form but MUST be human-readable. Empty provenance
is NOT PERMITTED for `Ready`-status cartridges.

---

## 11. Reference Implementation Pattern

The IDApTIK UMS (User Management System) cartridge is the **canonical reference
implementation** for how a cartridge crosses the Idris2 → Zig → Rust boundary.

### 11.1 Layer Stack

```
  ┌────────────────────────────────────┐
  │  Idris2 ABI (src/abi/)             │  Dependent types, erased proof fields,
  │  GuardsInZones, ZonesOrdered,      │  compile-time invariants
  │  PBXConsistent, DefenceTargets,    │
  │  DevicesExist                      │
  └─────────────────┬──────────────────┘
                    │  C-ABI integers / booleans
  ┌─────────────────▼──────────────────┐
  │  Zig FFI (ffi/zig/src/)            │  C-compatible implementation,
  │  ValidationResult { bool, bool,    │  mirrors every Idris2 type as a
  │    bool, bool, bool }              │  boolean struct for FFI export
  └─────────────────┬──────────────────┘
                    │  extern "C" + Tauri command wrappers
  ┌─────────────────▼──────────────────┐
  │  Rust Tauri commands               │  Named <cartridge>_cartridge_<op>
  │  (IDApTIK/src-tauri/src/           │  so BoJ routes:
  │   commands.rs)                     │  invoke("<name>_cartridge_<op>", …)
  └─────────────────┬──────────────────┘
                    │  shared filesystem bridge
  ┌─────────────────▼──────────────────┐
  │  Bridge directory                  │  /tmp/panll/<name>-bridge/
  │  /tmp/panll/ums-bridge/            │  for data exchange between
  │                                    │  Tauri backend and BoJ cartridge
  └────────────────────────────────────┘
```

### 11.2 Naming Convention

Rust Tauri command wrappers MUST follow the naming scheme:

```
  <cartridge>_cartridge_<op>
```

For example:

| Command name | Cartridge | Operation |
|-------------|-----------|-----------|
| `ums_cartridge_validate_guards` | `ums` | `validate_guards` |
| `ums_cartridge_check_zones` | `ums` | `check_zones` |
| `git_cartridge_clone` | `git` | `clone` |
| `database_cartridge_query` | `database` | `query` |

BoJ routes invocations using `invoke("<name>_cartridge_<op>", …)` where `<name>`
matches the `name` field in the cartridge manifest. This convention MUST be
followed for all cartridges that use the Tauri command wrapper pattern.

### 11.3 Idris2 Erased Proof Fields

Validation types in cartridge ABIs SHOULD use erased (runtime-zero-cost) proof
fields for their invariants, following the UMS pattern:

```idris
-- Proof fields with multiplicity 0 (erased at runtime):
record ZoneConfig where
  constructor MkZoneConfig
  zones        : List Zone
  0 zonesOk    : ZonesOrdered zones    -- erased; zero runtime cost
  0 pbxOk      : PBXConsistent zones   -- erased; zero runtime cost
```

The Zig FFI mirror exposes only the boolean results; the proofs themselves are
compile-time artefacts.

### 11.4 Canonical Reference File

The canonical reference for the Rust Tauri command pattern is:

```
IDApTIK/src-tauri/src/commands.rs
```

Do not reproduce the full file here; read it directly. The naming convention,
bridge directory structure, and extern declarations in that file are normative
for all cartridges following this pattern.

---

## 12. Relationship to Cartridge Tools

The cartridge-tools suite (minter, provisioner, configurator, panel harness)
**consumes** this specification. Every requirement in
[../cartridge-tools/README.md](../cartridge-tools/README.md) that refers to
cartridge structure, manifest fields, lifecycle states, or transport behaviour
is grounded in this document.

If there is ever a conflict between the cartridge-tools spec and this cartridge
spec, this document takes precedence (subject to the Idris2 source being
authoritative over both).

---

*This specification was extracted and consolidated on 2026-04-17 from*
*`src/abi/Boj/Catalogue.idr`, `src/abi/Boj/Protocol.idr`,*
*`src/abi/Boj/Domain.idr`, and `docs/papers/boj-architecture-paper.md` §§5–6.*
