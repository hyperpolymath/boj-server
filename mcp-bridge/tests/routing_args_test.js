// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — routed-tool argument tests
//
// The browser / cloud / comms / ml tools are routed to a shared
// cartridge with a routing key (`action` or `provider`) derived from
// the tool name. These tests pin two properties:
//   1. arguments outside a routed tool's inputSchema are refused, and
//   2. the routing key the cartridge receives always matches the tool
//      that was called.
// `fetch` is stubbed so no backend is needed.
//
// Run: node --test mcp-bridge/tests/routing_args_test.js

import { after, before, test } from "node:test";
import assert from "node:assert/strict";

import { dispatchMcpMessage } from "../lib/dispatcher.js";

// Some runners (bun) share one process across test files, so the stub is
// installed for this file only and the real fetch is put back afterwards.
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

const ROUTED = [
  ["boj_browser_read_page", {}, "action", "read_page"],
  ["boj_browser_screenshot", {}, "action", "screenshot"],
  ["boj_browser_navigate", { url: "https://example.org/" }, "action", "navigate"],
  ["boj_cloud_verpex", { operation: "list" }, "provider", "verpex"],
  ["boj_cloud_vercel", { operation: "list" }, "provider", "vercel"],
  ["boj_comms_calendar", { operation: "list" }, "provider", "calendar"],
  ["boj_ml_huggingface", { operation: "list" }, "provider", "huggingface"],
];

for (const [tool, args, key, expected] of ROUTED) {
  test(`${tool}: a well-formed call reaches the cartridge with ${key}=${expected}`, async () => {
    const { res, sent } = await call(tool, args);
    assert.equal(res.error, undefined, JSON.stringify(res.error));
    assert.equal(sent.length, 1);
    assert.equal(sent[0].body[key], expected);
  });

  test(`${tool}: an argument named '${key}' cannot change the routing`, async () => {
    const { res, sent } = await call(tool, { ...args, [key]: "something-else" });
    for (const s of sent) assert.equal(s.body[key], expected, "routing key was overridden");
    assert.ok(res.error, "expected the call to be refused");
    assert.equal(res.error.code, -32602);
  });
}

test("routed tools refuse arguments outside their inputSchema", async () => {
  const { res, sent } = await call("boj_browser_screenshot", { not_in_schema: 1 });
  assert.ok(res.error, "expected the call to be refused");
  assert.equal(res.error.code, -32602);
  assert.equal(sent.length, 0);
});

test("coord_send accepts its declared sender_role argument", async () => {
  const { res } = await call("coord_send", { message: "hi", target: "peer", sender_role: "apprentice" });
  assert.equal(res.error, undefined, JSON.stringify(res.error));
});
