#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# VPS redeploy script — run locally after `podman push ghcr.io/hyperpolymath/boj-server:latest`
# Usage: bash docs/outreach/vps-redeploy.sh
set -euo pipefail

VPS="root@209.42.26.106"
IMAGE="ghcr.io/hyperpolymath/boj-server:latest"

echo "==> Redeploying boj-server on $VPS"

ssh "$VPS" bash -s <<EOF
set -euo pipefail

echo "Pulling latest image..."
podman pull $IMAGE

echo "Stopping old container..."
podman stop boj-server 2>/dev/null || true
podman rm   boj-server 2>/dev/null || true

echo "Starting new container..."
podman run -d --name boj-server \
  --restart=always \
  -p 7700:7700 -p 7701:7701 -p 7702:7702 -p 7703:7703 \
  -v boj-server-data:/data \
  $IMAGE

echo "Waiting for health check..."
sleep 5
curl -sf http://localhost:7700/health && echo "Health: OK"

echo "Cartridge count:"
curl -sf http://localhost:7700/menu | python3 -c "
import sys, json
data = json.load(sys.stdin)
carts = data.get('cartridges', data.get('servers', []))
print(f'  {len(carts)} cartridges loaded')
" 2>/dev/null || curl -sf http://localhost:7700/menu | head -5

echo "Done."
EOF
