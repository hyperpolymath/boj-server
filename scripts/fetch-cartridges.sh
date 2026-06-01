#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# fetch-cartridges.sh — populate a host-local cartridge cache from the canonical
# hyperpolymath/boj-server-cartridges registry, for on-demand consumption by the
# Elixir catalog (BojRest.Catalog reads cartridge.json under <root>/*/).
#
# This is the runtime half of the cartridge-extraction migration (boj-server#158
# landed the catalog fallback chain; this script supplies the fetch the chain
# expects). It is additive: nothing invokes it until the catalog default is
# flipped to BOJ_CARTRIDGES_PATH, so it can ship ahead of that flip.
#
# The registry stores cartridges under a hybrid taxonomy
#   cartridges/domains/<domain>/<name>/
#   cartridges/cross-cutting/<category>/<name>/
# whereas the catalog expects a flat <root>/<name>/. This script flattens the
# tree as it populates the cache; cartridge names are unique across the registry,
# so the flatten cannot collide.
#
# Usage:
#   scripts/fetch-cartridges.sh [target-dir]
# Environment:
#   BOJ_CARTRIDGES_PATH  target cache dir (default: $HOME/.boj/cartridges);
#                        overridden by the positional argument when given.
#   BOJ_CARTRIDGES_REF   git ref to fetch (default: main).
#   BOJ_CARTRIDGES_REPO  source repo URL (default: the canonical GitHub registry).

set -euo pipefail

TARGET="${1:-${BOJ_CARTRIDGES_PATH:-$HOME/.boj/cartridges}}"
REF="${BOJ_CARTRIDGES_REF:-main}"
REPO="${BOJ_CARTRIDGES_REPO:-https://github.com/hyperpolymath/boj-server-cartridges.git}"

# Shallow-clone the registry into a scratch dir; remove it on any exit.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching cartridges from $REPO@$REF"
git clone --depth 1 --branch "$REF" "$REPO" "$WORK/registry"

SRC="$WORK/registry/cartridges"
if [ ! -d "$SRC" ]; then
    echo "error: no cartridges/ directory in the registry checkout" >&2
    exit 1
fi

# Strict-validate the registry before adopting its manifests. The registry's
# own CI gate already enforces this against main, but defense-in-depth means
# we never copy known-bad manifests into a host cache.
#
# Skip if the registry doesn't ship the Deno validator (older snapshots).
# Skip if Deno isn't installed on the host — the catalog will validate at
# load time regardless.
VALIDATOR="$WORK/registry/tools/validate-cartridges"
if [ -d "$VALIDATOR" ] && command -v deno >/dev/null 2>&1; then
    echo "Strict-validating registry manifests against bundled schema..."
    if ! (cd "$VALIDATOR" && deno task strict >/dev/null 2>&1); then
        echo "error: registry failed strict schema validation; refusing to populate cache" >&2
        echo "  re-run with verbose output:" >&2
        echo "    cd $VALIDATOR && deno task audit-verbose" >&2
        exit 1
    fi
    echo "  registry strict-valid"
else
    if [ ! -d "$VALIDATOR" ]; then
        echo "note: registry has no tools/validate-cartridges — skipping strict pre-validation"
    else
        echo "note: deno not installed — skipping strict pre-validation; catalog will validate at load"
    fi
fi

# Stage the flattened tree beside the target, then swap it in, so a concurrent
# reader never observes a half-populated cache.
STAGE="$(mktemp -d "${TARGET%/}.stage.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$WORK" "$STAGE"' EXIT

count=0
# Every directory that holds a cartridge.json is a cartridge root, at whatever
# depth the taxonomy nests it. Find them and copy each to <stage>/<name>/.
while IFS= read -r manifest; do
    cart_dir="$(dirname "$manifest")"
    name="$(basename "$cart_dir")"
    if [ -e "$STAGE/$name" ]; then
        echo "warning: duplicate cartridge name '$name' — keeping first, skipping $cart_dir" >&2
        continue
    fi
    cp -r "$cart_dir" "$STAGE/$name"
    count=$((count + 1))
done < <(find "$SRC" -type f -name cartridge.json | sort)

echo "Flattened $count cartridges"

# Also copy the registry's pinned schema mirror beside the cache. The Elixir
# catalog (BojRest.Catalog) defaults to looking for the schema at
# <root>/../schemas/cartridge-v1.json, so placing it as a sibling of the
# flattened cartridges directory makes the cache self-contained.
SCHEMA_SRC="$WORK/registry/schemas"
if [ -d "$SCHEMA_SRC" ]; then
    SCHEMA_STAGE="$STAGE.schemas"
    rm -rf "$SCHEMA_STAGE"
    cp -r "$SCHEMA_SRC" "$SCHEMA_STAGE"
fi

# Atomic-ish swap: move the old cache aside, move the new one in, drop the old.
# When schemas are present, swap them as a sibling of TARGET so the layout is
#   <parent>/cartridges/        (renamed from $STAGE)
#   <parent>/schemas/           (renamed from $STAGE.schemas)
mkdir -p "$(dirname "$TARGET")"
if [ -n "${SCHEMA_STAGE:-}" ]; then
    SCHEMA_TARGET="$(dirname "$TARGET")/schemas"
    if [ -e "$SCHEMA_TARGET" ]; then
        rm -rf "$SCHEMA_TARGET"
    fi
    mv "$SCHEMA_STAGE" "$SCHEMA_TARGET"
    echo "Schema mirror staged at $SCHEMA_TARGET"
fi

if [ -e "$TARGET" ]; then
    OLD="$(mktemp -d "${TARGET%/}.old.XXXXXX" 2>/dev/null || mktemp -d)"
    rm -rf "$OLD"
    mv "$TARGET" "$OLD"
    mv "$STAGE" "$TARGET"
    rm -rf "$OLD"
else
    mv "$STAGE" "$TARGET"
fi

echo "Cartridge cache ready at $TARGET ($count cartridges)"
echo "Point boj-server at it with: export BOJ_CARTRIDGES_PATH=$TARGET"
