// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Streamable HTTP transport tests (ADR-0013, PR1).
//
// Covers dispatch-parity with stdio, auth modes, session lifecycle, and
// the loopback-refuse safety gate. Mirrors `dispatch_test.js` patterns:
// `node --test`, runtime-neutral assertions, no fixtures of network
// services beyond loopback.
//
// Run: node --test mcp-bridge/tests/http_transport_test.js

import { test } from "node:test";
import assert from "node:assert/strict";

import { startHttpTransport, _internals } from "../lib/http-transport.js";

const { SessionManager, checkAuth, parseTokens, isLoopback, handleMcpPost } = _internals;

// Reserve an ephemeral port via the kernel rather than guessing.
async function pickEphemeralPort() {
  const { createServer } = await import("node:net");
  return new Promise((resolve, reject) => {
    const srv = createServer();
    srv.unref();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

async function withServer(opts, fn) {
  const port = opts.port ?? (await pickEphemeralPort());
  const handle = await startHttpTransport({ ...opts, port });
  try {
    return await fn({ handle, port });
  } finally {
    await handle.stop();
  }
}

// -----------------------------------------------------------------
// 1. SessionManager — create/touch/delete/expire semantics
// -----------------------------------------------------------------
test("SessionManager: create returns unique IDs", () => {
  const sm = new SessionManager();
  const a = sm.create();
  const b = sm.create();
  assert.notEqual(a, b);
  assert.ok(sm.get(a));
  assert.ok(sm.get(b));
});

test("SessionManager: touch fails for unknown sessions", () => {
  const sm = new SessionManager();
  assert.equal(sm.touch("not-a-real-uuid"), false);
});

test("SessionManager: expireIdle drops sessions older than the timeout", () => {
  const sm = new SessionManager({ timeoutMs: 1000 });
  const id = sm.create();
  // simulate the session having been idle for two hours
  sm.get(id).lastSeenMs = Date.now() - 2 * 60 * 60 * 1000;
  const removed = sm.expireIdle();
  assert.equal(removed, 1);
  assert.equal(sm.get(id), undefined);
});

// -----------------------------------------------------------------
// 2. checkAuth — bearer reject / accept; none permissive
// -----------------------------------------------------------------
test("checkAuth: bearer accepts a known token", () => {
  const result = checkAuth({
    authMode: "bearer",
    tokens: new Set(["alpha", "beta"]),
    headerValue: "Bearer alpha",
  });
  assert.equal(result.ok, true);
});

test("checkAuth: bearer rejects unknown tokens with 401", () => {
  const result = checkAuth({
    authMode: "bearer",
    tokens: new Set(["alpha"]),
    headerValue: "Bearer wrong",
  });
  assert.equal(result.ok, false);
  assert.equal(result.code, 401);
});

test("checkAuth: bearer rejects missing Authorization header", () => {
  const result = checkAuth({ authMode: "bearer", tokens: new Set(["x"]), headerValue: undefined });
  assert.equal(result.ok, false);
  assert.equal(result.code, 401);
});

test("checkAuth: bearer rejects malformed Authorization header", () => {
  const result = checkAuth({ authMode: "bearer", tokens: new Set(["x"]), headerValue: "Basic xyz" });
  assert.equal(result.ok, false);
  assert.equal(result.code, 401);
});

test("checkAuth: none mode always passes", () => {
  const result = checkAuth({ authMode: "none", tokens: new Set(), headerValue: undefined });
  assert.equal(result.ok, true);
});

// -----------------------------------------------------------------
// 3. parseTokens — CSV normalisation
// -----------------------------------------------------------------
test("parseTokens: trims whitespace and drops empty entries", () => {
  const got = parseTokens(" a, b ,, c ");
  assert.deepEqual([...got].sort(), ["a", "b", "c"]);
});

test("parseTokens: empty input is an empty Set", () => {
  assert.equal(parseTokens("").size, 0);
  assert.equal(parseTokens(undefined).size, 0);
});

// -----------------------------------------------------------------
// 4. isLoopback — host classification
// -----------------------------------------------------------------
test("isLoopback: recognises loopback addresses", () => {
  for (const h of ["127.0.0.1", "localhost", "::1"]) assert.equal(isLoopback(h), true);
});

test("isLoopback: rejects 0.0.0.0 and public addresses", () => {
  for (const h of ["0.0.0.0", "10.0.0.1", "203.0.113.7"]) assert.equal(isLoopback(h), false);
});

// -----------------------------------------------------------------
// 5. startup-safety — auth=none + non-loopback refuses to start
// -----------------------------------------------------------------
test("startHttpTransport: refuses auth=none on a non-loopback bind", async () => {
  await assert.rejects(
    () => startHttpTransport({ port: 0, bind: "0.0.0.0", authMode: "none", tokens: [] }),
    /Refusing to start.*non-loopback/i,
  );
});

test("startHttpTransport: refuses bearer mode with no tokens", async () => {
  await assert.rejects(
    () => startHttpTransport({ port: 0, bind: "127.0.0.1", authMode: "bearer", tokens: [] }),
    /requires at least one token/i,
  );
});

// -----------------------------------------------------------------
// 6. handleMcpPost — pure-ish dispatch (no live socket)
// -----------------------------------------------------------------
test("handleMcpPost: initialize mints a session id and returns the MCP serverInfo", async () => {
  const sessions = new SessionManager();
  const out = await handleMcpPost({
    rawBody: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "t" } } }),
    headers: {},
    sessions,
    auth: { authMode: "none", tokens: new Set() },
  });
  assert.equal(out.status, 200);
  assert.ok(out.headers["Mcp-Session-Id"], "session id header must be present");
  assert.equal(out.body.result.serverInfo.name, "boj-server");
  // session is recorded
  assert.ok(sessions.get(out.headers["Mcp-Session-Id"]));
});

test("handleMcpPost: rejects unknown session id with -32001", async () => {
  const sessions = new SessionManager();
  const out = await handleMcpPost({
    rawBody: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }),
    headers: { "mcp-session-id": "not-a-known-session" },
    sessions,
    auth: { authMode: "none", tokens: new Set() },
  });
  assert.equal(out.status, 404);
  assert.equal(out.body.error.code, -32001);
});

test("handleMcpPost: bearer auth rejects unauthenticated requests", async () => {
  const sessions = new SessionManager();
  const out = await handleMcpPost({
    rawBody: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }),
    headers: {},
    sessions,
    auth: { authMode: "bearer", tokens: new Set(["secret"]) },
  });
  assert.equal(out.status, 401);
});

test("handleMcpPost: bearer auth accepts a valid token", async () => {
  const sessions = new SessionManager();
  const out = await handleMcpPost({
    rawBody: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }),
    headers: { authorization: "Bearer secret" },
    sessions,
    auth: { authMode: "bearer", tokens: new Set(["secret"]) },
  });
  assert.equal(out.status, 200);
});

test("handleMcpPost: malformed JSON returns -32700 Parse error", async () => {
  const sessions = new SessionManager();
  const out = await handleMcpPost({
    rawBody: "{not json",
    headers: {},
    sessions,
    auth: { authMode: "none", tokens: new Set() },
  });
  assert.equal(out.status, 400);
  assert.equal(out.body.error.code, -32700);
});

test("handleMcpPost: notifications/initialized returns 202 with empty body", async () => {
  const sessions = new SessionManager();
  // First, mint a session via initialize so the notification carries a valid id.
  const init = await handleMcpPost({
    rawBody: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }),
    headers: {},
    sessions,
    auth: { authMode: "none", tokens: new Set() },
  });
  const sessionId = init.headers["Mcp-Session-Id"];
  const out = await handleMcpPost({
    rawBody: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
    headers: { "mcp-session-id": sessionId },
    sessions,
    auth: { authMode: "none", tokens: new Set() },
  });
  assert.equal(out.status, 202);
  assert.equal(out.body, "");
});

// -----------------------------------------------------------------
// 7. End-to-end through the real listener — initialize + tools/list
// -----------------------------------------------------------------
test("HTTP listener: end-to-end initialize then tools/list with session header", async () => {
  await withServer({ bind: "127.0.0.1", authMode: "none", tokens: [] }, async ({ port }) => {
    const initRes = await fetch(`http://127.0.0.1:${port}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "e2e" } } }),
    });
    assert.equal(initRes.status, 200);
    const sessionId = initRes.headers.get("mcp-session-id");
    assert.ok(sessionId, "Mcp-Session-Id must be issued on initialize");
    const initBody = await initRes.json();
    assert.equal(initBody.result.serverInfo.name, "boj-server");

    const toolsRes = await fetch(`http://127.0.0.1:${port}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Mcp-Session-Id": sessionId },
      body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }),
    });
    assert.equal(toolsRes.status, 200);
    const toolsBody = await toolsRes.json();
    assert.ok(Array.isArray(toolsBody.result.tools));
    assert.ok(toolsBody.result.tools.length > 0);
  });
});

test("HTTP listener: bearer mode rejects request without token, accepts with token", async () => {
  await withServer({ bind: "127.0.0.1", authMode: "bearer", tokens: ["s3cret"] }, async ({ port }) => {
    const noAuth = await fetch(`http://127.0.0.1:${port}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }),
    });
    assert.equal(noAuth.status, 401);

    const withAuth = await fetch(`http://127.0.0.1:${port}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": "Bearer s3cret" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }),
    });
    assert.equal(withAuth.status, 200);
  });
});

test("HTTP listener: GET /healthz returns 200 without auth", async () => {
  await withServer({ bind: "127.0.0.1", authMode: "bearer", tokens: ["t"] }, async ({ port }) => {
    const res = await fetch(`http://127.0.0.1:${port}/healthz`);
    assert.equal(res.status, 200);
  });
});

test("HTTP listener: unknown path 404s", async () => {
  await withServer({ bind: "127.0.0.1", authMode: "none", tokens: [] }, async ({ port }) => {
    const res = await fetch(`http://127.0.0.1:${port}/nope`);
    assert.equal(res.status, 404);
  });
});

test("HTTP listener: DELETE /mcp tears down a session", async () => {
  await withServer({ bind: "127.0.0.1", authMode: "none", tokens: [] }, async ({ port, handle }) => {
    const initRes = await fetch(`http://127.0.0.1:${port}/mcp`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize" }),
    });
    const sessionId = initRes.headers.get("mcp-session-id");
    assert.ok(handle.sessions.get(sessionId));
    const del = await fetch(`http://127.0.0.1:${port}/mcp`, {
      method: "DELETE",
      headers: { "Mcp-Session-Id": sessionId },
    });
    assert.equal(del.status, 204);
    assert.equal(handle.sessions.get(sessionId), undefined);
  });
});

// -----------------------------------------------------------------
// 8. boj_capabilities deployment resource
// -----------------------------------------------------------------
test("resources: boj://capabilities/deployment lists the 5 local-only cartridges", async () => {
  const { readResource, listResources } = await import("../lib/resources.js");
  const uris = listResources().map((r) => r.uri);
  assert.ok(uris.includes("boj://capabilities/deployment"), "must advertise the deployment-capabilities resource");
  const r = await readResource("boj://capabilities/deployment");
  assert.ok(r && r.contents[0].text);
  const payload = JSON.parse(r.contents[0].text);
  const names = payload.local_only_cartridges.map((c) => c.name).sort();
  assert.deepEqual(
    names,
    ["browser-mcp", "container-mcp", "ffmpeg-mcp", "local-coord-mcp", "sandbox-mcp"],
    "ADR-0013 PR1 names 5 local-only cartridges",
  );
  for (const c of payload.local_only_cartridges) {
    assert.equal(c.requires_local, true);
    assert.ok(typeof c.reason === "string" && c.reason.length > 0);
  }
});
