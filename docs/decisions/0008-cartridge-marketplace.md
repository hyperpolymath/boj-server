<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# 8. Cartridge marketplace — discovery, submission, and Ayo-tier activation

Date: 2026-05-20

## Status

Proposed (RFC — implementation tracked in epic #87 item 10)

## Context

BoJ defines three trust tiers (see ADR-0007). **Teranga** (formally verified) and **Shield** (security-reviewed) cartridges ship in this repo; both tiers are populated. **Ayo** — described as "community contributions, master-approval-gated" — has exactly **one** member at present (`local-coord-mcp` in the offline manifest, though that's actually a first-party cartridge that landed in the Ayo tier organisationally rather than as community work).

The third tier exists in vocabulary but has no:

- Submission protocol for third-party authors
- Discovery surface for users to find community cartridges
- Verification path from "Ayo" (community-submitted) → "Shield" (security-reviewed) → "Teranga" (formally verified)
- Trust signal (signing, provenance, supply-chain claims) that lets BoJ tell the user "this is community, treat accordingly"

Without these, "Ayo" is effectively an inactive label. The estate cannot grow beyond what the maintainer personally writes — counter to BoJ's consolidation mission, which depends on long-tail domain coverage. ADR-0002 (BoJ-only MCP) means a third-party MCP server **cannot** be the answer; capabilities must come into BoJ as cartridges.

## Decision

Build a **federated cartridge marketplace** with three components, in increasing order of trust:

1. **Marketplace index** — a content-addressed registry of community cartridges (Ayo)
2. **Submission protocol** — how a third-party author proposes a cartridge for Ayo listing
3. **Promotion path** — how an Ayo cartridge moves to Shield (security review) and Shield → Teranga (formal verification)

### Marketplace index

A new repository `hyperpolymath/cartridge-index` (separate from boj-server). It is **not** a binary registry; it's a manifest registry. Each entry in `index.a2ml` (machine-readable, MPL-2.0) is:

```a2ml
- name: example-mcp
  version: 0.1.0
  tier: ayo
  source:
    type: git
    url: https://github.com/<author>/<repo>
    rev: <40-char-sha>      # content-pinned, not branch-tracked
  manifest_sha256: <hash>   # of the source's cartridge.json at <rev>
  abi_sha256: <hash>        # of the Idris2 ABI .ttc bundle
  signature:
    algorithm: ML-DSA-87    # estate quantum-safe standard
    public_key_id: <kid>    # author's published key
    signature: <hex>        # over (name|version|source|manifest_sha256|abi_sha256)
  author:
    name: <human-readable>
    contact: <email-or-github>
  domain: <single keyword e.g. "imaging", "iot", "finance">
  short_description: <120 chars max>
  declared_policy: policies/<name>.ncl   # mandatory per ADR-0007
  proof_obligations: []                  # empty for Ayo by definition; populated when promoted to Shield
  estate_review: null                    # populated only when promoted to Shield
```

BoJ reads the index by syncing the repo. A new bridge tool `boj_marketplace_search` queries the synced index. A second tool `boj_marketplace_install` performs the install dance (fetch source at pinned rev, verify hashes + signature, build locally, place under `cartridges/`).

### Submission protocol

A community author submits a PR against `hyperpolymath/cartridge-index/inbox/`. The PR contains:

1. The proposed index entry (signed)
2. A link to the cartridge source repo at the pinned rev
3. Evidence that the cartridge:
   - Has a `cartridge.json` manifest matching the manifest_sha256
   - Has Idris2 ABI + Zig FFI + adapter (standard triple)
   - Has a `policies/<name>.ncl` file matching ADR-0007's schema
   - Has a passing `npm test` (or equivalent) on the submitted rev
   - Carries `SPDX-License-Identifier: CC-BY-SA-4.0` (or OSI-approved equivalent)
4. A signed CLA-equivalent (`SIGNED-OFF-BY` in commit, with verified email)

A CI workflow in `cartridge-index` runs:

- Hash verification (manifest + ABI)
- Signature verification (ML-DSA-87 against published keys)
- Policy schema validation (Nickel against ADR-0007 contract)
- Source-tree compliance (file structure matches cartridge convention)
- Per-author rate limit (max 5 submissions per 30 days; prevents spam)

A maintainer reviews and merges. The cartridge becomes discoverable via `boj_marketplace_search`. It is **never installed automatically**; the user must explicitly `boj_marketplace_install` it.

### Promotion path

| From | To | Requirements |
|---|---|---|
| _outside_ | Ayo | Submission PR accepted; cartridge becomes installable but never default-loaded |
| Ayo | Shield | (a) Hypatia neurosymbolic scan passes; (b) `panic-attack-mcp` static analysis passes; (c) explicit security review from a designated reviewer; (d) reviewer signs the promotion entry; (e) `estate_review` field populated with reviewer + date + scope |
| Shield | Teranga | (a) Idris2 ABI declares one or more proof obligations; (b) all obligations discharged (no `believe_me`); (c) cross-cartridge composition with at least three other Teranga cartridges proves safe; (d) declared and discharged in `boj://proofs/manifest` |

Promotion is recorded in `cartridge-index` itself (the entry's `tier` and `estate_review` fields update). The cartridge source repo does not change; only the index entry promotes.

### Default install posture

Out of the box, BoJ only enables **Teranga** + **Shield** cartridges. Ayo cartridges are visible (via `boj_marketplace_search`) but require explicit user action (`boj_marketplace_install` + an `--accept-ayo-tier` flag) to be loaded. Once installed, ADR-0007's policy engine treats them appropriately: tier-3/4 operations require master approval.

### Discovery surface

Two new bridge tools:

- `boj_marketplace_search` — query the synced index by name / domain / tier; read-only
- `boj_marketplace_install` — fetch + verify + build + activate a community cartridge

Plus a new MCP resource (per PR #89's vocabulary):

- `boj://marketplace/index` — full index dump (synced from `cartridge-index` repo)
- `boj://marketplace/cartridges/<name>` — single entry

## Consequences

### Positive

- **Activates the Ayo tier** — gives it a concrete protocol, not just a label.
- **Long-tail coverage without ADR-0002 violation** — community capabilities flow into BoJ as cartridges, not as standalone MCPs.
- **Trust signal is explicit and verifiable** — ML-DSA-87 signatures, content-pinned source, hash-verified ABI. Aligns with the estate's quantum-safe-provenance branding.
- **Promotion path matches existing vocabulary** — security review is what makes Shield, formal verification is what makes Teranga. The marketplace doesn't invent new trust criteria; it formalises the ones BoJ already implicitly uses.
- **Decouples release cadence** — community cartridges ship on their own schedule via index PRs; boj-server proper doesn't need to release for the catalogue to grow.
- **Default-safe** — Ayo is never auto-loaded, never auto-enabled. The user explicitly opts in per cartridge.

### Negative

- **Maintenance burden on `cartridge-index`** — requires a designated reviewer pool. Mitigation: federate the maintainer set; not solo-bus-factor.
- **CLA / contribution legal surface** — needs careful drafting. Use Developer Certificate of Origin (DCO) rather than custom CLA where possible.
- **Build reproducibility** — community cartridge `manifest_sha256` is straightforward, but the `abi_sha256` requires deterministic Idris2 builds. Achievable but requires submitter discipline.
- **Discoverability vs noise** — the catalogue could fill with low-quality cartridges. Mitigation: per-author rate limit + maintainer curation gate at the inbox PR step.
- **Update protocol** — when an installed Ayo cartridge has a new version in the index, how does the user learn? `boj_marketplace_check_updates` tool emitting a notification (depends on ADR-0011 / item 5).

## Non-goals

- Not building a paid/commercial marketplace. Open-source-only.
- Not building hosted binary distribution. The index points at source repos; users build locally. This avoids supply-chain attacks against a central tarball cache and keeps the trust model close to git provenance.
- Not requiring community cartridges to be formally verified for Ayo listing. Verification is the *promotion* criterion to Shield/Teranga, not the entry bar to Ayo.
- Not auto-installing security updates for Ayo cartridges. Updates are user-initiated only. Notifications (depends on ADR-0011) inform; they don't act.

## Open questions

1. **Index repository hosting** — `hyperpolymath/cartridge-index` on GitHub is the obvious choice. Alternative: host on the hyperpolymath estate forge (if/when there is one) for sovereignty. Recommend GitHub for now; revisit if estate forge ships.

2. **Reviewer compensation** — security review is labour. For Shield/Teranga promotion, who pays? Initial answer: volunteer + maintainer time. If this scales, consider a CodeFund-style sponsored review fund.

3. **Cartridge deprecation** — when an author abandons a cartridge or it's superseded by another, how is the index entry marked? Recommend `status: active | deprecated | superseded-by:<name>` field on every entry.

4. **Forking and divergence** — what if two authors submit cartridges that wrap the same upstream service (e.g. two `pinecone-mcp` variants)? Recommend allow both, list both, let users choose. Don't pick favorites in the index.

5. **Estate-internal cartridge promotion** — does this protocol apply to the 115 first-party cartridges already in boj-server? Recommend no: the in-repo cartridges are subject to in-repo CI; the marketplace exists for third-party submissions. The in-repo set is the "starter catalogue" that initial users see.

6. **What signs the index?** — the index repo itself is signed by maintainers (per `cartridge-index` CI). Individual entries are also signed by their authors. Both signatures verify on `boj_marketplace_install`.

## Linked

- ADR-0002 (BoJ-only MCP) — third-party capabilities cannot ship as standalone MCPs; this is how they ship instead.
- ADR-0007 (trust-tier policy DSL) — mandates a default policy per cartridge; this RFC requires it as a submission gate.
- Epic #87 item 10 (this) + item 4 (the policy DSL precondition).
- EXHIBIT-B (Quantum-Safe Provenance) — ML-DSA-87 standard reused here for cartridge author signatures.
