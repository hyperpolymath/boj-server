#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Deploy (or re-deploy) all 4 Umoja seed nodes to fly.io.
# Run from the boj-server repo root:
#   bash container/fly/deploy-seeds.sh
#
# Prerequisites: fly CLI authenticated (fly auth whoami)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

declare -A NODES=(
  [eu]="lhr"
  [de]="fra"
  [us]="iad"
  [ap]="syd"
)

echo "=== BoJ Seed Node Deployment ==="
echo "Authenticated as: $(fly auth whoami)"
echo

for region_code in eu de us ap; do
  app="boj-seed-${region_code}"
  fly_region="${NODES[$region_code]}"
  config="container/fly/fly-${region_code}.toml"

  echo "--- ${app} (${fly_region}) ---"

  # Create app if it doesn't exist
  if ! fly apps list | grep -q "^[[:space:]]*${app}"; then
    echo "  Creating app ${app}..."
    fly apps create "${app}" --org personal
  else
    echo "  App ${app} already exists."
  fi

  # Create volume if none exist for this app
  vol_count=$(fly volumes list --app "${app}" 2>/dev/null | grep -c "boj_data" || true)
  if [ "${vol_count}" -eq 0 ]; then
    echo "  Creating 1 GB volume boj_data in ${fly_region}..."
    fly volumes create boj_data \
      --app "${app}" \
      --region "${fly_region}" \
      --size 1 \
      --yes
  else
    echo "  Volume already exists (${vol_count} found)."
  fi

  echo "  Deploying ${app}..."
  fly deploy \
    --app "${app}" \
    --config "${config}" \
    --dockerfile container/Containerfile.fly \
    --remote-only \
    --wait-timeout 900

  echo "  Done. Health: https://${app}.fly.dev/health"
  echo
done

echo "=== All 4 seed nodes deployed ==="
echo
echo "REST endpoints:"
for region_code in eu de us ap; do
  echo "  https://boj-seed-${region_code}.fly.dev/health"
done
echo
echo "Update container/seed-nodes.toml and compose.prod.yaml with .fly.dev hostnames."
