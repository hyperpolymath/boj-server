#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# boj-selinux-contexts.sh — Set persistent SELinux file contexts for BoJ server
# Must be run with sudo. Persists across restorecon / relabels.
#
# Usage: sudo ./scripts/boj-selinux-contexts.sh
#
# The bundled cartridges/ tree was retired (canonical source:
# hyperpolymath/boj-server-cartridges). Cartridge .so files now live under a
# host-local cache populated by scripts/fetch-cartridges.sh, so the cartridge
# rule is written against that cache root rather than against the repo.
#
# Environment:
#   BOJ_CARTRIDGES_PATH  cartridge cache root (default: $HOME/.boj/cartridges).
#                        Under sudo, $HOME is root's — pass this explicitly
#                        (sudo BOJ_CARTRIDGES_PATH=... ./scripts/...) to label
#                        a cache that belongs to the invoking user.

set -euo pipefail

# Derive repo root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BOJ_ROOT="$(dirname "$SCRIPT_DIR")"
readonly CARTRIDGES_ROOT="${BOJ_CARTRIDGES_PATH:-$HOME/.boj/cartridges}"

# SELinux has an equivalency rule: /var/mnt -> /mnt
# semanage fcontext requires the /mnt/... form for rule paths.
# Strip /var prefix if present (semanage needs canonical /mnt paths).
readonly BOJ_ROOT_SEMANAGE="${BOJ_ROOT#/var}"
readonly CARTRIDGES_ROOT_SEMANAGE="${CARTRIDGES_ROOT#/var}"

echo "=== BoJ Server SELinux Context Setup ==="

# 1. Cartridge shared libraries: lib_t
if [ -d "$CARTRIDGES_ROOT" ]; then
    echo "[1/2] Setting fcontext rule: cartridge .so files -> lib_t ($CARTRIDGES_ROOT)"
    semanage fcontext -a -t lib_t \
        "${CARTRIDGES_ROOT_SEMANAGE}/.*/ffi/zig-out/lib/.*\\.so" 2>/dev/null \
        || semanage fcontext -m -t lib_t \
        "${CARTRIDGES_ROOT_SEMANAGE}/.*/ffi/zig-out/lib/.*\\.so"
else
    echo "[1/2] SKIP: no cartridge cache at $CARTRIDGES_ROOT."
    echo "      Populate one with scripts/fetch-cartridges.sh, or set"
    echo "      BOJ_CARTRIDGES_PATH, then re-run to label cartridge .so files."
fi

# 2. Core FFI shared libraries: lib_t
echo "[2/2] Setting fcontext rule: core FFI .so files -> lib_t"
semanage fcontext -a -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/ffi/zig/zig-out/lib/.*\\.so" 2>/dev/null \
    || semanage fcontext -m -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/ffi/zig/zig-out/lib/.*\\.so"

# Apply the contexts
echo "Applying contexts with restorecon..."
if [ -d "$CARTRIDGES_ROOT" ]; then
    restorecon -Rv "${CARTRIDGES_ROOT}/" 2>&1 || true
fi
restorecon -Rv "${BOJ_ROOT}/ffi/" 2>&1 || true

echo "=== Done. Verify with: ls -Z ${BOJ_ROOT}/ffi/zig/zig-out/lib/ ==="
if [ -d "$CARTRIDGES_ROOT" ]; then
    echo "===       and: ls -Z ${CARTRIDGES_ROOT}/*/ffi/zig-out/lib/ ==="
fi
