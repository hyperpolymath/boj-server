#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# boj-selinux-contexts.sh — Set persistent SELinux file contexts for BoJ server
# Must be run with sudo. Persists across restorecon / relabels.
#
# Usage: sudo ./scripts/boj-selinux-contexts.sh

set -euo pipefail

# SELinux has an equivalency rule: /var/mnt -> /mnt
# semanage fcontext requires the /mnt/... form for rule paths
readonly BOJ_ROOT_SEMANAGE="/mnt/eclipse/repos/boj-server"
# Actual filesystem path for restorecon
readonly BOJ_ROOT="/var/mnt/eclipse/repos/boj-server"

echo "=== BoJ Server SELinux Context Setup ==="

# 1. Binary: bin_t (already correct, make persistent)
echo "[1/3] Setting fcontext rule: adapter binary -> bin_t"
semanage fcontext -a -t bin_t \
    "${BOJ_ROOT_SEMANAGE}/adapter/v/boj-server" 2>/dev/null \
    || semanage fcontext -m -t bin_t \
    "${BOJ_ROOT_SEMANAGE}/adapter/v/boj-server"

# 2. Cartridge shared libraries: lib_t
echo "[2/3] Setting fcontext rule: cartridge .so files -> lib_t"
semanage fcontext -a -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/cartridges/.*/ffi/zig-out/lib/.*\\.so" 2>/dev/null \
    || semanage fcontext -m -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/cartridges/.*/ffi/zig-out/lib/.*\\.so"

# 3. Core FFI shared libraries: lib_t
echo "[3/3] Setting fcontext rule: core FFI .so files -> lib_t"
semanage fcontext -a -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/ffi/zig/zig-out/lib/.*\\.so" 2>/dev/null \
    || semanage fcontext -m -t lib_t \
    "${BOJ_ROOT_SEMANAGE}/ffi/zig/zig-out/lib/.*\\.so"

# Apply the contexts
echo "Applying contexts with restorecon..."
restorecon -v "${BOJ_ROOT}/adapter/v/boj-server" 2>&1 || true
restorecon -Rv "${BOJ_ROOT}/cartridges/" 2>&1 || true
restorecon -Rv "${BOJ_ROOT}/ffi/" 2>&1 || true

echo "=== Done. Verify with: ls -Z ${BOJ_ROOT}/adapter/v/boj-server ==="
echo "=== And: ls -Z ${BOJ_ROOT}/cartridges/database-mcp/ffi/zig-out/lib/ ==="
