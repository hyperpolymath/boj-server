#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Regenerate site/catalog.json from the canonical cartridge registry.
# The site serves a committed snapshot; run this when the registry changes.
#
# Usage:
#   tools/site-catalog/build-catalog.sh [CARTRIDGES_REPO] [OUT]
# Defaults:
#   CARTRIDGES_REPO=../boj-server-cartridges   OUT=site/catalog.json
#
# Requires: jq. Groups by the registry's directory taxonomy (reliable), not the
# free-text `domain` field. Excludes templates/. Honours an explicit `available:false`.

set -euo pipefail

CARTRIDGES_REPO="${1:-../boj-server-cartridges}"
OUT="${2:-site/catalog.json}"
GEN_DATE="$(date -u +%Y-%m-%d)"
REGISTRY="https://github.com/hyperpolymath/boj-server-cartridges"

command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 1; }
[ -d "$CARTRIDGES_REPO/cartridges" ] || { echo "error: no cartridges/ under $CARTRIDGES_REPO" >&2; exit 1; }

cd "$CARTRIDGES_REPO"
tmp="$(mktemp)"
{
  printf '{\n  "schema": "boj-site-catalog/v1",\n'
  printf '  "generated": "%s",\n  "registry": "%s",\n  "cartridges": [\n' "$GEN_DATE" "$REGISTRY"
  first=1
  while IFS= read -r f; do
    rel="${f#./}"
    case "$rel" in cartridges/templates/*) continue;; esac
    IFS='/' read -r _c grp bucket _name _rest <<<"$rel"
    dir="$(dirname "$rel")"
    if [ $first -eq 1 ]; then first=0; else printf ',\n'; fi
    jq -c --arg group "$grp" --arg bucket "$bucket" --arg path "$dir" '{
      name, version: (.version // "0.0.0"), description: (.description // ""),
      tier: (.tier // "Ayo"), domain: (.domain // ""), category: (.category // ""),
      protocols: (.protocols // []), auth: (.auth.method // "none"),
      toolCount: ((.tools // []) | length),
      available: (if has("available") then .available else true end),
      group: $group, bucket: $bucket, path: $path
    }' "$f" | tr -d '\n'
  done < <(find cartridges -name cartridge.json | sort)
  printf '\n  ]\n}\n'
} >"$tmp"

jq -e . "$tmp" >/dev/null || { echo "error: produced invalid JSON" >&2; rm -f "$tmp"; exit 1; }
cd - >/dev/null
mv "$tmp" "$OUT"
echo "wrote $OUT ($(jq '.cartridges|length' "$OUT") cartridges)"
