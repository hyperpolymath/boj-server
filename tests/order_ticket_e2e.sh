#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# BoJ Server — End-to-end order-ticket test (FFI layer only).
#
# Tests the full order-ticket flow WITHOUT the V-lang server by exercising
# the Zig FFI catalogue directly via a dedicated test module
# (ffi/zig/src/e2e_order.zig).
#
# Usage:
#   bash tests/order_ticket_e2e.sh
#
# Prerequisites:
#   - Zig 0.15+ on PATH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_DIR="$PROJECT_DIR/ffi/zig"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

echo "================================================================="
echo "  BoJ Server — Order-Ticket E2E (Zig FFI, no V server)"
echo "================================================================="
echo ""

# --- Step 1: Verify Zig is available ---
echo "Step 1: Checking Zig toolchain..."
if ! command -v zig &>/dev/null; then
    red "  FAIL: zig not found on PATH"
    exit 1
fi
ZIG_VER="$(zig version 2>&1)"
green "  Zig version: $ZIG_VER"

# --- Step 2: Build the catalogue library ---
echo ""
echo "Step 2: Building catalogue library..."
cd "$ZIG_DIR"
if zig build lib 2>&1; then
    green "  Catalogue library built"
else
    red "  FAIL: catalogue library build failed"
    exit 1
fi

# --- Step 3: Run the e2e order-ticket tests ---
echo ""
echo "Step 3: Running e2e order-ticket tests..."
cd "$ZIG_DIR"
if zig build e2e --summary all 2>&1; then
    green "  All e2e order-ticket tests passed"
else
    red "  FAIL: e2e order-ticket tests failed"
    exit 1
fi

# --- Step 4: Run the standard catalogue unit tests for completeness ---
echo ""
echo "Step 4: Running catalogue unit tests..."
cd "$ZIG_DIR"
if zig build test --summary all 2>&1; then
    green "  All unit tests passed"
else
    red "  FAIL: unit tests failed"
    exit 1
fi

# --- Summary ---
echo ""
echo "================================================================="
green "  Order-Ticket E2E: ALL PASS"
echo ""
echo "  Tested flow:"
echo "    - Catalogue init/deinit"
echo "    - Register 4 cartridges (database-mcp, fleet-mcp, nesy-mcp, agent-mcp)"
echo "    - Protocol assignment per cartridge"
echo "    - Hash attestation (set + round-trip verify)"
echo "    - Mount 3 cartridges (order simulation)"
echo "    - Mounted count and per-cartridge is_mounted checks"
echo "    - Catalogue count/ready/mounted queries"
echo "    - Unmount one, verify count drops"
echo "    - Negative: development cartridge mount rejected"
echo "    - Negative: out-of-bounds mount rejected"
echo "================================================================="
