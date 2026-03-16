#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Benchmarks for hetzner-mcp cartridge.
set -euo pipefail

echo "=== hetzner-mcp benchmarks ==="

cd "$(dirname "${BASH_SOURCE[0]}")/../ffi"

# Build with ReleaseFast for benchmarking
zig build -Doptimize=ReleaseFast 2>&1

echo "Session open/close cycle (1000 iterations):"
time for i in $(seq 1 1000); do
    # This would call the FFI benchmark binary
    true
done

echo ""
echo "Benchmark placeholder — implement real benchmarks in Zig test blocks"
echo "or via the V-lang adapter HTTP benchmark tool."
