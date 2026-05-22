#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Integration tests for vault-mcp cartridge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CART_DIR="$(dirname "$SCRIPT_DIR")"
FFI_DIR="$CART_DIR/ffi"

echo "=== vault-mcp integration tests ==="

# Build FFI
echo "[1/4] Building FFI..."
cd "$FFI_DIR" && zig build 2>&1

# Run Zig unit tests (state machine, audit, allowlist)
echo "[2/4] Running FFI unit tests..."
cd "$FFI_DIR" && zig build test 2>&1

# Validate Idris2 ABI (if idris2 available)
echo "[3/4] Checking ABI..."
if command -v idris2 &>/dev/null; then
    cd "$CART_DIR/abi" && idris2 --check VaultMcp.SafeSecrets 2>&1
    echo "  ABI: OK"
else
    echo "  ABI: SKIPPED (idris2 not in PATH)"
fi

# Validate MCP tool definitions
echo "[4/4] Validating MCP tool definitions..."
if [ -f "$CART_DIR/mcp-tools.json" ]; then
    # Check JSON is valid
    if command -v deno &>/dev/null; then
        deno eval "const t = JSON.parse(await Deno.readTextFile('$CART_DIR/mcp-tools.json')); console.log('  Tools:', t.tools.length, 'defined'); for (const tool of t.tools) { console.log('    -', tool.name); }" 2>&1
    elif command -v python3 &>/dev/null; then
        python3 -c "import json; t=json.load(open('$CART_DIR/mcp-tools.json')); print(f'  Tools: {len(t[\"tools\"])} defined')"
    else
        echo "  MCP tools: JSON present (no validator available)"
    fi
else
    echo "  MCP tools: MISSING (mcp-tools.json not found)"
    exit 1
fi

echo ""
echo "All tests passed for vault-mcp!"
