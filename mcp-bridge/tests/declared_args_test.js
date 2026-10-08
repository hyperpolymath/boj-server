// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — declared-argument tests
//
// Every tool's inputSchema sets additionalProperties:false. These tests pin
// that the bridge enforces it for every tool in the full list (plus the
// deprecated alias), not only the routed ones: an argument the schema does
// not declare is refused before dispatch. `fetch` is stubbed so no backend
// is needed.
//
// Run: node --test mcp-bridge/tests/declared_args_test.js

import { after, before, test } from "node:test";
import assert from "node:assert/strict";

import { dispatchMcpMessage, validateDeclaredArgs } from "../lib/dispatcher.js";
import { buildToolList } from "../lib/tools.js";

const posted = [];
const realFetch = globalThis.fetch;
before(() => {
  globalThis.fetch = async (url, init) => {
    posted.push({ url: String(url), body: init?.body ? JSON.parse(init.body) : null });
    return { ok: true, status: 200, json: async () => ({ ok: true }) };
  };
});
after(() => {
  globalThis.fetch = realFetch;
});

let nextId = 1;
/** Issue one tools/call and return the JSON-RPC response plus what was posted. */
async function call(name, args) {
  posted.length = 0;
  const res = await dispatchMcpMessage({
    jsonrpc: "2.0",
    id: nextId++,
    method: "tools/call",
    params: { name, arguments: args },
  });
  return { res, sent: [...posted] };
}

const TOOLS = buildToolList("full");
const NAMES = [...TOOLS.map((t) => t.name), "coord_promote_to_supervisor"];

test("the full tool list is non-empty and every schema is closed", () => {
  assert.ok(TOOLS.length > 0);
  for (const t of TOOLS) assert.equal(t.inputSchema?.additionalProperties, false, t.name);
});

// Checked directly rather than through tools/call, so the per-minute rate
// limit cannot turn a refusal into a different error.
for (const name of NAMES) {
  test(`${name}: an undeclared argument is refused`, () => {
    assert.equal(validateDeclaredArgs(name, { not_in_schema: 1 }), `Unexpected argument 'not_in_schema' for ${name}`);
  });
}

for (const t of TOOLS) {
  test(`${t.name}: every declared argument is accepted`, () => {
    const args = Object.fromEntries(Object.keys(t.inputSchema.properties ?? {}).map((k) => [k, "x"]));
    const routed = t.name.match(/^boj_(browser|cloud|comms|ml)_/);
    if (routed) {
      delete args.action;
      delete args.provider;
    }
    assert.equal(validateDeclaredArgs(t.name, args), null);
  });
}

test("a tool outside the list is unknown to the argument check", () => {
  assert.equal(validateDeclaredArgs("boj_not_a_tool", {}), "Unknown tool");
});

test("tools/call refuses an undeclared argument on a non-routed tool before dispatch", async () => {
  const { res, sent } = await call("boj_search", { operation: "web", query: "q", not_in_schema: 1 });
  assert.ok(res.error, "expected the call to be refused");
  assert.equal(res.error.code, -32602);
  assert.match(res.error.message, /Unexpected argument 'not_in_schema'/);
  assert.equal(sent.length, 0);
});

test("tools/call refuses an undeclared argument on a coord tool before dispatch", async () => {
  const { res, sent } = await call("coord_list_peers", { token: "t", not_in_schema: 1 });
  assert.ok(res.error, "expected the call to be refused");
  assert.equal(res.error.code, -32602);
  assert.equal(sent.length, 0);
});

test("tools/call reports an unlisted tool as unknown", async () => {
  const { res } = await call("boj_not_a_tool", {});
  assert.equal(res.error?.code, -32601);
});
