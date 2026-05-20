// SPDX-License-Identifier: MPL-2.0
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
//    regression can't slip through review. Bumped 80 -> 120 after the
//    April 2026 AAA audit raised the weakest tools.
// -----------------------------------------------------------------
test("every tool has a description at least 120 chars long", () => {
  const thin = tools.filter(
    (t) => !t.description || t.description.length < 120,
  );
  assert.equal(
    thin.length,
    0,
    `Thin tool descriptions (hurts Glama AAA score): ${thin.map((t) => `${t.name}=${t.description?.length ?? 0}`).join(", ")}`,
  );
});

// -----------------------------------------------------------------
// 3b. Mean description length must stay above the AAA healthy floor.
//     Glama scores the MEAN of tool descriptions (60% of TDQS); this
//     guards against death-by-a-thousand-cuts regressions where every
//     tool stays above the MIN floor but collectively the mean drops.
// -----------------------------------------------------------------
test("mean description length stays above 200 chars", () => {
  const mean =
    tools.reduce((sum, t) => sum + (t.description?.length ?? 0), 0) /
    tools.length;
  assert.ok(
    mean >= 200,
    `Mean description length ${mean.toFixed(1)} dropped below the 200-char AAA floor.`,
  );
});

// -----------------------------------------------------------------
// 3c. Every tool's schema must set `additionalProperties: false` so
//     unknown keys are rejected. Glama scores this under Parameter
//     Semantics; open schemas hide typos and violate strict-mode
//     clients.
// -----------------------------------------------------------------
test("every inputSchema sets additionalProperties: false", () => {
  const open = tools.filter(
    (t) => t.inputSchema?.additionalProperties !== false,
  );
  assert.equal(
    open.length,
    0,
    `Tools with open schemas: ${open.map((t) => t.name).join(", ")}`,
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

// -----------------------------------------------------------------
// 7. MCP annotations — every advertised tool must carry the full
//    MCP-spec annotations block: a non-empty Title-Case `title`
//    string plus the four boolean behaviour hints. Glama and modern
//    MCP clients surface these for safety/UX; a missing or
//    wrong-typed hint is a coherence regression.
// -----------------------------------------------------------------
test("every tool has a complete annotations block", () => {
  const HINTS = [
    "readOnlyHint",
    "destructiveHint",
    "idempotentHint",
    "openWorldHint",
  ];
  for (const t of tools) {
    assert.ok(
      t.annotations && typeof t.annotations === "object",
      `${t.name}: missing annotations object`,
    );
    assert.equal(
      typeof t.annotations.title,
      "string",
      `${t.name}: annotations.title must be a string`,
    );
    assert.ok(
      t.annotations.title.length > 0,
      `${t.name}: annotations.title must be non-empty`,
    );
    for (const h of HINTS) {
      assert.equal(
        typeof t.annotations[h],
        "boolean",
        `${t.name}: annotations.${h} must be a boolean`,
      );
    }
  }
});

// -----------------------------------------------------------------
// 8. outputSchema — every advertised tool must declare a JSON Schema
//    object describing its return, with a non-empty top-level
//    description and an explicit additionalProperties flag (Glama
//    scores documented return shapes).
// -----------------------------------------------------------------
test("every tool has a typed, described outputSchema", () => {
  for (const t of tools) {
    assert.ok(
      t.outputSchema && typeof t.outputSchema === "object",
      `${t.name}: missing outputSchema`,
    );
    assert.equal(
      t.outputSchema.type,
      "object",
      `${t.name}: outputSchema.type must be "object"`,
    );
    assert.equal(
      typeof t.outputSchema.description,
      "string",
      `${t.name}: outputSchema.description must be a string`,
    );
    assert.ok(
      t.outputSchema.description.length > 0,
      `${t.name}: outputSchema.description must be non-empty`,
    );
    assert.equal(
      typeof t.outputSchema.additionalProperties,
      "boolean",
      `${t.name}: outputSchema.additionalProperties must be set explicitly`,
    );
  }
});

// -----------------------------------------------------------------
// 9. BOJ_TOOL_SCOPE back-compat — with the env var unset (and no
//    explicit scope arg), buildToolList() must advertise the FULL
//    surface. This guards the default-preserving contract: scoping
//    is opt-in and must never silently shrink an existing client's
//    tool list.
// -----------------------------------------------------------------
test("BOJ_TOOL_SCOPE unset advertises the full surface (back-compat)", () => {
  const saved = process.env.BOJ_TOOL_SCOPE;
  try {
    delete process.env.BOJ_TOOL_SCOPE;
    const full = buildToolList();
    // The full surface includes explicit domain tools that `core`
    // would drop — assert a representative explicit tool is present.
    const names = new Set(full.map((t) => t.name));
    assert.ok(
      names.has("boj_github_list_repos"),
      "explicit boj_github_* tools must be advertised when scope is unset",
    );
    assert.ok(
      names.has("boj_browser_navigate"),
      "explicit boj_browser_* tools must be advertised when scope is unset",
    );
    assert.equal(
      full.length,
      tools.length,
      "unset scope must match the module-load full surface length",
    );

    // And `core` must be a strict subset (the scope lever works).
    const core = buildToolList("core");
    assert.ok(
      core.length < full.length,
      "core scope must advertise fewer tools than full",
    );
    const coreNames = new Set(core.map((t) => t.name));
    assert.ok(
      !coreNames.has("boj_github_list_repos"),
      "core scope must NOT advertise explicit boj_github_* tools",
    );
    assert.ok(
      coreNames.has("boj_cartridge_invoke"),
      "core scope must keep boj_cartridge_invoke (unified endpoint)",
    );
    assert.ok(
      [...coreNames].some((n) => n.startsWith("coord_")),
      "core scope must keep the coord_* coordination unit",
    );
  } finally {
    if (saved === undefined) delete process.env.BOJ_TOOL_SCOPE;
    else process.env.BOJ_TOOL_SCOPE = saved;
  }
});

// -----------------------------------------------------------------
// 12. resources/list surface — every resource declared has a valid
//     boj:// URI and a non-empty description.
// -----------------------------------------------------------------
test("resources surface is well-formed", async () => {
  const { listResources, readResource } = await import("../lib/resources.js");
  const resources = listResources();
  assert.ok(resources.length > 0, "must expose at least one resource");
  for (const r of resources) {
    assert.match(r.uri, /^boj:\/\//, `URI must start with boj://: ${r.uri}`);
    assert.ok(r.name && r.name.length > 0, `name required: ${r.uri}`);
    assert.ok(r.description && r.description.length > 20, `description must be substantive: ${r.uri}`);
    assert.ok(r.mimeType, `mimeType required: ${r.uri}`);
  }
  // boj://server/info is offline-readable and must work
  const info = await readResource("boj://server/info");
  assert.ok(info && info.contents && info.contents[0]?.text?.includes("boj-server"));
  // Unknown URI returns null
  const missing = await readResource("boj://nope/nada");
  assert.equal(missing, null);
});

// -----------------------------------------------------------------
// 13. prompts/list surface — every prompt has required-argument
//     validation and produces a non-empty message body.
// -----------------------------------------------------------------
test("prompts surface is well-formed and required-arg-validated", async () => {
  const { listPrompts, getPrompt } = await import("../lib/prompts.js");
  const prompts = listPrompts();
  assert.ok(prompts.length >= 6, "must expose at least 6 BoJ prompts");
  for (const p of prompts) {
    assert.ok(p.name && /^[a-z][a-z0-9-]*$/.test(p.name), `kebab-case name: ${p.name}`);
    assert.ok(p.description && p.description.length > 30, `description must be substantive: ${p.name}`);
    assert.ok(Array.isArray(p.arguments), `arguments must be array: ${p.name}`);
  }
  // Missing required arg → error
  const missingArg = getPrompt("audit-repo", {});
  assert.ok(missingArg.error, "missing required arg must produce error");
  assert.match(missingArg.error.message, /requires argument/);
  // Unknown prompt → error
  const unknown = getPrompt("does-not-exist", {});
  assert.ok(unknown.error);
  // Valid call → non-empty message
  const ok = getPrompt("audit-repo", { owner: "hyperpolymath", repo: "boj-server" });
  assert.ok(ok.result?.messages?.[0]?.content?.text?.length > 100);
});
