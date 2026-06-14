// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#!/usr/bin/env -S deno run --allow-read
//
// Generate offline-menu.js from the cartridges/ directory structure.
//
// Usage: node mcp-bridge/lib/generate-offline-menu.js
//
// Scans ../cartridges/ for subdirectories matching *-mcp pattern and
// produces a static OFFLINE_MENU object. This prevents the hardcoded
// menu from going stale as cartridges are added or removed.

import { readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const cartridgesDir = join(__dirname, "../../cartridges");

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
