<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) -->

# Cartridge schema mirror

The file `cartridge-v1.json` in this directory is a **vendored mirror** of the canonical schema living at:

- **Canonical home:** [`hyperpolymath/standards`](https://github.com/hyperpolymath/standards/blob/main/cartridges/cartridge-v1.json) (filed as PR [#200](https://github.com/hyperpolymath/standards/pull/200) on 2026-05-26).
- **Canonical URL:** `https://hyperpolymath.dev/standards/cartridges/cartridge-v1.json`

When the standards PR merges, this file should be SHA-pinned to the merged content. Pinning ceremony:

1. After standards#200 merges, capture the commit SHA in `hyperpolymath/standards`.
2. Capture the SHA-256 of `cartridges/cartridge-v1.json` at that commit.
3. Update [`PINNED-SHA`](PINNED-SHA) in this directory with both values (commit SHA + file SHA-256).

## Why mirror

1. **Offline validation.** The Elixir BoJ catalog (`elixir/lib/boj_rest/catalog.ex`) reads cartridges from disk at boot; validation against the canonical URL would require network calls that are out of scope for the catalog.
2. **Reproducibility.** A given boj-server build must validate cartridges against a deterministic schema version, so the bundled mirror is the source of truth at runtime.

## What if local and canonical disagree?

Standards wins. Local mirror is always advancing toward standards. When standards moves to v2, this mirror will get a `cartridge-v2.json` and the consumer code will accept both v1 and v2 manifests for a deprecation period.

See also:
- standards [ADR-002 — cartridge format canonical home](https://github.com/hyperpolymath/standards/blob/main/docs/decisions/ADR-002-cartridge-format-canonical-home.adoc)
- boj-server-cartridges [`schemas/SCHEMA-MIRROR.md`](https://github.com/hyperpolymath/boj-server-cartridges/blob/main/schemas/SCHEMA-MIRROR.md) (same content, different repo — keep both in sync)
