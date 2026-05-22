#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Benchmarks for sentry-mcp cartridge.
set -euo pipefail

echo "=== sentry-mcp benchmarks ==="

cd "$(dirname "${BASH_SOURCE[0]}")/../ffi"

zig build -Doptimize=ReleaseFast 2>&1

echo "Session open/close cycle (1000 iterations):"
time for i in $(seq 1 1000); do
    true
done

echo ""
echo "Benchmark placeholder -- implement real benchmarks in Zig test blocks"
echo "or via the zig adapter HTTP benchmark tool."
