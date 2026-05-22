#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Integration tests for circleci-mcp cartridge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CART_DIR="$(dirname "$SCRIPT_DIR")"
FFI_DIR="$CART_DIR/ffi"

echo "=== circleci-mcp integration tests ==="

echo "[1/3] Building FFI..."
cd "$FFI_DIR" && zig build 2>&1

echo "[2/3] Running FFI unit tests..."
cd "$FFI_DIR" && zig build test 2>&1

echo "[3/3] Checking ABI..."
if command -v idris2 &>/dev/null; then
    cd "$CART_DIR/abi" && idris2 --check CircleciMcp.SafeRegistry 2>&1
    echo "  ABI: OK"
else
    echo "  ABI: SKIPPED (idris2 not in PATH)"
fi

echo ""
echo "All tests passed for circleci-mcp!"
