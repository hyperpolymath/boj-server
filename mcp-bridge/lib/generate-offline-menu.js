#!/usr/bin/env -S deno run --allow-read --allow-env
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Generate offline-menu.js from a cartridge catalog directory.
//
// Usage: BOJ_CARTRIDGES_PATH=~/.boj/cartridges node mcp-bridge/lib/generate-offline-menu.js
//
// Scans the catalog root (flat <name>/ layout — populate one from the
// canonical hyperpolymath/boj-server-cartridges registry with
// scripts/fetch-cartridges.sh) for subdirectories matching the *-mcp
// pattern and produces a static OFFLINE_MENU object. This prevents the
// hardcoded menu from going stale as cartridges are added or removed.
// The bundled ../../cartridges tree this used to scan was retired.

import { readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const cartridgesDir =
  Deno.env.get("BOJ_CARTRIDGES_PATH") ?? join(__dirname, "../../cartridges");

try {
  const entries = readdirSync(cartridgesDir)
    .filter(name => {
      const full = join(cartridgesDir, name);
      return statSync(full).isDirectory() && name.endsWith("-mcp");
    })
    .sort();

  console.log(`Found ${entries.length} cartridges in ${cartridgesDir}`);
  console.log("Cartridges:", entries.join(", "));
  console.log("\nUpdate mcp-bridge/lib/offline-menu.js with any new cartridges.");
} catch (err) {
  console.error(`Error scanning cartridges directory: ${err.message}`);
  Deno.exit(1);
}
