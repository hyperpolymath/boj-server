#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
#
# refresh-bundled-cartridges.sh — bring boj-server's bundled cartridges/ in sync
# with the canonical hyperpolymath/boj-server-cartridges registry while
# preserving the existing 125-cartridge curation.
#
# Differences from fetch-cartridges.sh:
#   * fetch-cartridges.sh populates a host-local cache (default $HOME/.boj)
#     from the FULL canonical (currently 139 cartridges).
#   * this script overwrites the IN-TREE cartridges/ dir with the canonical
#     content for only the names currently present in the bundle.
#
# Run from the repo root:
#   scripts/refresh-bundled-cartridges.sh [registry-clone-dir]
#
# If no registry path is given, the script clones the canonical registry into
# a scratch dir and uses that.
#
# Three cartridges were renamed in boj-server-cartridges PR #27 to match the
# canonical schema's name pattern. The legacy bundled name maps to the new
# canonical name as follows:
#
#   boj-health    → boj-health-mcp
#   origenemcp    → origene-mcp
#   opendatamcp   → opendata-mcp

set -euo pipefail

REGISTRY="${1:-}"
WORK=""

cleanup() {
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

if [ -z "$REGISTRY" ]; then
    WORK="$(mktemp -d)"
    REGISTRY="$WORK/registry"
    echo "Cloning canonical registry into $REGISTRY"
    git clone --quiet --depth 1 https://github.com/hyperpolymath/boj-server-cartridges.git "$REGISTRY"
fi

if [ ! -d "$REGISTRY/cartridges" ]; then
    echo "error: $REGISTRY/cartridges not found" >&2
    exit 1
fi

if [ ! -d "cartridges" ]; then
    echo "error: run from repo root (cartridges/ not found here)" >&2
    exit 1
fi

# Build a name-mapping function. For most cartridges old==new; the rename trio
# from boj-server-cartridges#27 is handled explicitly.
canonical_name_for() {
    local old="$1"
    case "$old" in
        boj-health)   echo "boj-health-mcp" ;;
        origenemcp)   echo "origene-mcp" ;;
        opendatamcp)  echo "opendata-mcp" ;;
        *)            echo "$old" ;;
    esac
}

# Find a cartridge in the canonical registry by name. Returns the directory
# under $REGISTRY/cartridges/{domains|cross-cutting|templates}/.../$name/.
find_canonical_dir() {
    local name="$1"
    # mindepth 2 admits templates (cartridges/templates/<name>) alongside
    # domains/<d>/<name> and cross-cutting/<c>/<name>.
    find "$REGISTRY/cartridges" -mindepth 2 -maxdepth 4 -type d -name "$name" | head -n 1
}

# Walk the existing bundle. README.md is not a cartridge.
refreshed=0
renamed=0
missing=0
for bundled_dir in cartridges/*/; do
    bundled="${bundled_dir%/}"
    bundled_name="$(basename "$bundled")"
    canonical_name="$(canonical_name_for "$bundled_name")"
    canonical_dir="$(find_canonical_dir "$canonical_name")"

    if [ -z "$canonical_dir" ]; then
        echo "MISSING in canonical: $bundled_name (no $canonical_name in registry)"
        missing=$((missing + 1))
        continue
    fi

    # If the name changed, drop the legacy directory.
    if [ "$bundled_name" != "$canonical_name" ]; then
        echo "RENAME: $bundled_name -> $canonical_name"
        rm -rf "cartridges/$bundled_name"
        renamed=$((renamed + 1))
    else
        rm -rf "cartridges/$bundled_name"
    fi

    cp -r "$canonical_dir" "cartridges/$canonical_name"
    refreshed=$((refreshed + 1))
done

echo
echo "Summary"
echo "  refreshed: $refreshed"
echo "  renamed:   $renamed"
echo "  missing:   $missing"
