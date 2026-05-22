#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# boj-health-check.sh — Post-start health check for BoJ server
# Waits up to 10 seconds for the /health endpoint to return HTTP 200.
# Used as ExecStartPost in the systemd service.

set -euo pipefail

readonly MAX_WAIT=10
readonly URL="http://localhost:7700/health"

for i in $(seq 1 "$MAX_WAIT"); do
    if curl -sf -o /dev/null -w '' "$URL" 2>/dev/null; then
        echo "boj-server health check passed after ${i}s"
        exit 0
    fi
    sleep 1
done

echo "boj-server health check FAILED — /health did not return 200 within ${MAX_WAIT}s" >&2
exit 1
