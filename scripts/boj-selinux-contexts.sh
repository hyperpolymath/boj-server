#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# boj-selinux-contexts.sh — Set persistent SELinux file contexts for BoJ server
# Must be run with sudo. Persists across restorecon / relabels.
#
# Usage: sudo ./scripts/boj-selinux-contexts.sh

set -euo pipefail

# Derive repo root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BOJ_ROOT="$(dirname "$SCRIPT_DIR")"

# SELinux has an equivalency rule: /var/mnt -> /mnt
# semanage fcontext requires the /mnt/... form for rule paths.
# Strip /var prefix if present (semanage needs canonical /mnt paths).
readonly BOJ_ROOT_SEMANAGE="${BOJ_ROOT#/var}"

echo "=== BoJ Server SELinux Context Setup ==="

# 1. Cartridge shared libraries: lib_t
echo "[1/2] Setting fcontext rule: cartridge .so files -> lib_t"
semanage fcontext -a -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/cartridges/.*/ffi/zig-out/lib/.*\\.so" 2>/dev/null \
    || semanage fcontext -m -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/cartridges/.*/ffi/zig-out/lib/.*\\.so"

# 2. Core FFI shared libraries: lib_t
echo "[2/2] Setting fcontext rule: core FFI .so files -> lib_t"
semanage fcontext -a -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/ffi/zig/zig-out/lib/.*\\.so" 2>/dev/null \
    || semanage fcontext -m -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/ffi/zig/zig-out/lib/.*\\.so"

# Apply the contexts
echo "Applying contexts with restorecon..."
restorecon -Rv "${BOJ_ROOT}/cartridges/" 2>&1 || true
restorecon -Rv "${BOJ_ROOT}/ffi/" 2>&1 || true

echo "=== Done. Verify with: ls -Z ${BOJ_ROOT}/cartridges/database-mcp/ffi/zig-out/lib/ ==="
