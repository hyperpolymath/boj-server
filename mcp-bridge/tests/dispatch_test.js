// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP tool-surface coherence tests
//
// These tests verify that the MCP bridge's advertised tool list stays
// in sync with the local-coord-mcp cartridge manifest. Glama scores
// server coherence — missing tools, stale names, or loose schemas all
// lower the AAA-tier score. Keep this test green.
//
// Run: node --test mcp-bridge/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { buildToolList } from "../lib/tools.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const cartridgePath = join(
  __dirname,
  "../../cartridges/local-coord-mcp/cartridge.json",
);

const tools = buildToolList();
const byName = new Map(tools.map((t) => [t.name, t]));

// -----------------------------------------------------------------
// 1. Every coord_* tool in the cartridge manifest is exposed by the
//    bridge. (Stale bridge = invisible to Glama.)
// -----------------------------------------------------------------
test("every coord_* tool in cartridge.json is exposed by the bridge", () => {
  const cartridge = JSON.parse(readFileSync(cartridgePath, "utf8"));
  const cartridgeCoord = (cartridge.tools || [])
    .map((t) => t.name)
    .filter((n) => n.startsWith("coord_"))
    .sort();

  const bridgeCoord = tools
    .map((t) => t.name)
    .filter((n) => n.startsWith("coord_") && n !== "coord_promote_to_supervisor")
    .sort();

  assert.deepEqual(
    bridgeCoord,
    cartridgeCoord,
    "MCP bridge tool list drifted from cartridge.json — regenerate after adding/removing FFI exports.",
  );
});

// -----------------------------------------------------------------
// 2. DD-32 rename: coord_promote_to_master is canonical; the old
//    `_to_supervisor` name is kept only as a dispatch alias, not
//    advertised in the tool list.
// -----------------------------------------------------------------
test("coord_promote_to_master is canonical (DD-32 rename)", () => {
  assert.ok(
    byName.has("coord_promote_to_master"),
    "coord_promote_to_master must be advertised",
  );
  assert.ok(
    !byName.has("coord_promote_to_supervisor"),
    "coord_promote_to_supervisor should not be re-advertised — accepted at dispatch only",
  );
});

// -----------------------------------------------------------------
// 3. AAA-tier description floor. Glama's tool-definition quality
//    score (60% mean + 40% MIN) collapses if any single tool has a
//    thin description. Enforce a minimum character count so a
//    regression can't slip through review.
// -----------------------------------------------------------------
test("every tool has a description at least 80 chars long", () => {
  const thin = tools.filter(
    (t) => !t.description || t.description.length < 80,
  );
  assert.equal(
    thin.length,
    0,
    `Thin tool descriptions (hurts Glama AAA score): ${thin.map((t) => `${t.name}=${t.description?.length ?? 0}`).join(", ")}`,
  );
});

// -----------------------------------------------------------------
// 4. Every tool has a valid inputSchema object — no bare `{}`
//    schemas, no missing `type: "object"`. Glama scores this under
//    Parameter Semantics.
// -----------------------------------------------------------------
test("every tool's inputSchema is a typed object", () => {
  for (const t of tools) {
    assert.ok(t.inputSchema, `${t.name}: missing inputSchema`);
    assert.equal(
      t.inputSchema.type,
      "object",
      `${t.name}: inputSchema.type must be "object"`,
    );
    assert.ok(
      t.inputSchema.properties !== undefined,
      `${t.name}: inputSchema.properties missing`,
    );
  }
});

// -----------------------------------------------------------------
// 5. Required-parameter semantics — if `required` is set, every
//    name in it must be a declared property. A mismatch would make
//    the tool un-callable.
// -----------------------------------------------------------------
test("required[] names match declared properties", () => {
  for (const t of tools) {
    const req = t.inputSchema.required || [];
    const props = Object.keys(t.inputSchema.properties || {});
    for (const r of req) {
      assert.ok(
        props.includes(r),
        `${t.name}: required param "${r}" not in properties`,
      );
    }
  }
});

// -----------------------------------------------------------------
// 6. Tool names are unique — duplicates would break MCP dispatch.
// -----------------------------------------------------------------
test("tool names are unique", () => {
  const names = tools.map((t) => t.name);
  const dup = names.filter((n, i) => names.indexOf(n) !== i);
  assert.deepEqual(dup, [], `Duplicate tool names: ${dup.join(", ")}`);
});
