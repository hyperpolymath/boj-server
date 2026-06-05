#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Truthfulness invariant for the cartridge catalogue.
#
# The catalogue must never claim availability it cannot back. A cartridge is
# `available: true` ONLY when it is built and its tools return real results;
# anything else is `available: false`. This check fails CI the moment that
# contract is broken — so the catalogue can never quietly drift back to
# advertising stubs as working software.
#
# Rules (JSON, always):
#   A. status == "stub"  must NOT be available:true   (no stub advertised real)
#   B. status == "ready" <=> available == true        (crisp, single truth gate)
#   C. available:true must declare ffi.so_path
#
# Rules (--probe, when a Zig toolchain is present — i.e. in CI):
#   D. every available:true cartridge builds its .so, and invoking its first
#      tool returns a NON-stub result (no `"status":"stub"` marker, non-empty).
#
# Usage:  bash tests/truthfulness_check.sh [--probe]
set -euo pipefail
cd "$(dirname "$0")/.."

PROBE=0
[ "${1:-}" = "--probe" ] && PROBE=1

INVOKE=ffi/zig/zig-out/bin/boj-invoke
fail=0
note() { printf '%s\n' "$*"; }
err()  { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

if [ "$PROBE" = 1 ]; then
  if ! command -v zig >/dev/null 2>&1; then
    note "WARN: --probe requested but zig not on PATH; running JSON checks only"
    PROBE=0
  elif [ ! -x "$INVOKE" ]; then
    note "Building boj-invoke (required for --probe)…"
    (cd ffi/zig && zig build invoke) || { err "could not build boj-invoke"; PROBE=0; }
  fi
fi

checked=0
for f in cartridges/*/cartridge.json; do
  checked=$((checked + 1))
  name=$(jq -r '.name // "?"' "$f")
  avail=$(jq -r '.available // false' "$f")
  status=$(jq -r '.status // "catalogued"' "$f")

  # A — a stub must never be advertised available.
  if [ "$status" = "stub" ] && [ "$avail" = "true" ]; then
    err "$name: status=stub but available=true (stub advertised as working)"
  fi

  # B — ready <=> available.
  if [ "$status" = "ready" ] && [ "$avail" != "true" ]; then
    err "$name: status=ready but available=$avail (ready must be available)"
  fi
  if [ "$avail" = "true" ] && [ "$status" != "ready" ]; then
    err "$name: available=true but status=$status (available must be 'ready')"
  fi

  [ "$avail" = "true" ] || continue

  # C — available must declare an .so.
  so_rel=$(jq -r '.ffi.so_path // empty' "$f")
  if [ -z "$so_rel" ]; then
    err "$name: available=true but no ffi.so_path declared"
    continue
  fi
  cart_dir=$(dirname "$f")
  so_path="$cart_dir/$so_rel"

  if [ "$PROBE" = 1 ]; then
    # D — build fresh (never trust a committed binary), then probe the first
    # tool for a real (non-stub) reply.
    if [ -f "$cart_dir/ffi/build.zig" ]; then
      (cd "$cart_dir/ffi" && zig build) || err "$name: zig build failed"
    fi
    if [ ! -f "$so_path" ]; then
      err "$name: available=true but .so missing/unbuildable at $so_path"
      continue
    fi
    tool=$(jq -r '.tools[0].name // empty' "$f")
    if [ -z "$tool" ]; then
      err "$name: available=true but declares no tools[]"
      continue
    fi
    out=$("$INVOKE" "$so_path" invoke "$tool" '{}' 2>/dev/null || true)
    if [ -z "$out" ]; then
      err "$name: tool '$tool' produced no output (load failure / cli_missing)"
    elif printf '%s' "$out" | grep -qE '"status"[[:space:]]*:[[:space:]]*"stub"'; then
      err "$name: tool '$tool' returned a stub marker -> $out"
    else
      note "ok(probe): $name/$tool -> ${out:0:72}"
    fi
  else
    if [ ! -f "$so_path" ]; then
      note "WARN: $name available=true but .so not present at $so_path (CI --probe builds+verifies it)"
    else
      note "ok(json): $name (.so present at $so_path)"
    fi
  fi
done

echo "---"
if [ "$fail" = 0 ]; then
  note "truthfulness: OK — $checked cartridges checked (probe=$PROBE)"
else
  note "truthfulness: FAILED — see FAIL lines above"
fi
exit "$fail"
