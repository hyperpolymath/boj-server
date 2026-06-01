<!--
SPDX-License-Identifier: MPL-2.0
Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
-->

# boj-server / cartridges/

**This directory is a fetcher-managed cache.** It is not the source of truth.

## Source of truth

The canonical cartridge registry is [`hyperpolymath/boj-server-cartridges`](https://github.com/hyperpolymath/boj-server-cartridges). All cartridge additions, removals, and version bumps land there first. Hosts (`boj-server`, `panll`, others) fetch cartridges from that registry into a host-local cache.

This `cartridges/` directory ships a **snapshot** (currently 125 cartridges, snapshot 2026-05-26) so that:

1. `boj-server` boots without network access on first run.
2. The Elixir catalog (`elixir/lib/boj_rest/catalog.ex`) has something to read until the operator runs the fetcher.
3. Tests / integration scenarios can exercise the dispatch path without depending on a remote.

The bundled set is **a strict subset** of the canonical registry. As of 2026-06-01, 14 cartridges exist canonical-only and are not bundled:
`cloud-lsp, container-lsp, database-lsp, git-lsp, iac-lsp, k8s-lsp, librarian-mcp, npc-mcp, observe-lsp, proof-lsp, queues-lsp, secrets-lsp, ssg-lsp, stack-orchestrator-mcp`.

## Refreshing the cache

```bash
scripts/fetch-cartridges.sh                    # → $HOME/.boj/cartridges
scripts/fetch-cartridges.sh /path/to/cache     # → explicit target
BOJ_CARTRIDGES_PATH=/path scripts/fetch-cartridges.sh  # → env override
BOJ_CARTRIDGES_REF=v0.2 scripts/fetch-cartridges.sh    # → pin a ref
```

Per `scripts/fetch-cartridges.sh` (PR #169, 2026-05-31), this:

1. Shallow-clones the canonical registry at the requested ref.
2. Finds every `cartridge.json` and flattens its parent dir into `<target>/<name>/`.
3. Atomically swaps the staged result into the target via `mv`.

The Elixir catalog reads from `BOJ_CARTRIDGES_PATH` if set, falling back to this bundled directory.

## Known divergence

Three drift modes between the bundled snapshot and the canonical registry are documented in the project memory (`project_boj_server_cartridges_sync_2026_06_01.md`). Summarised here so this README is self-contained:

1. **Schema drift on `category` field.** Bundled `cartridge.json` files include `"category"` (added by PR #158). Canonical files lack it. Operators who run the fetcher silently lose the `category` field; downstream consumers that expect it must handle absence. Tracked as a pre-existing risk; no fix scheduled.
2. **Duplicate-name collisions in flattening.** The fetcher's claim that "cartridge names are unique across the registry" is not currently enforced. If a `domains/X/foo-mcp` and `cross-cutting/Y/foo-mcp` ever coexist, `find | sort` first-wins and the other is silently dropped with only a stderr warning.
3. **Stale bundled set.** Default-config operators (who never run the fetcher) see the 14-cartridge deficit indefinitely. No scheduled re-bundling is in place.

The catalog (`catalog.ex`) does **no** schema validation — it silently accepts any JSON object with a `"name"` field. Adding a schema check is a candidate Eno-tier improvement (see `docs/planning/boj-server-proof-story-2026-06-01.md` §4 W1).

## Authoring new cartridges

**Do not author here.** Open a PR in [`hyperpolymath/boj-server-cartridges`](https://github.com/hyperpolymath/boj-server-cartridges) against the canonical registry. Once merged there, refresh this snapshot via a coordinated re-bundle PR.

The canonical cartridge format spec is at [`hyperpolymath/standards/cartridges/CARTRIDGE-FORMAT.adoc`](https://github.com/hyperpolymath/standards/blob/main/cartridges/CARTRIDGE-FORMAT.adoc); the JSON schema is `schemas/cartridge-v1.json` in the same repo.

## Cross-references

- Canonical registry: [`hyperpolymath/boj-server-cartridges`](https://github.com/hyperpolymath/boj-server-cartridges)
- Fetcher script: `scripts/fetch-cartridges.sh` (PR #169)
- Catalog loader: `elixir/lib/boj_rest/catalog.ex`
- Cartridge spec: [`hyperpolymath/standards/cartridges/CARTRIDGE-FORMAT.adoc`](https://github.com/hyperpolymath/standards/blob/main/cartridges/CARTRIDGE-FORMAT.adoc)
- Planning context: `docs/planning/cartridge-catalogue-2026-06-01.md` (PR #179), `docs/planning/boj-server-proof-story-2026-06-01.md` (PR #180)
