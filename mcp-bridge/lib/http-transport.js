// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP Streamable HTTP transport (per ADR-0013, PR1 of 2)
//
// Adds an HTTP+SSE transport alongside stdio. Same `dispatchMcpMessage`,
// same `hardeningGate`, same tool surface — only the I/O layer differs.
//
// Endpoints:
//   POST /mcp     — submit a JSON-RPC request, get a JSON response
//   GET  /mcp     — open an SSE stream for server-initiated notifications
//   GET  /healthz — liveness probe (200 OK, no auth)
//
// Headers:
//   Mcp-Session-Id     — server-issued on `initialize`; client sends it
//                        on every subsequent request
//   Authorization      — `Bearer <token>` when BOJ_HTTP_AUTH=bearer
//
// Zero deps. Uses Deno.serve / node:http via runtime detection.

import { isDeno, env } from "./runtime.js";
import { dispatchMcpMessage } from "./dispatcher.js";
import { info, warn, error as logError } from "./logger.js";

const DEFAULT_PORT = 7780;
const DEFAULT_BIND = "127.0.0.1";
const SESSION_TIMEOUT_MS = 30 * 60 * 1000; // 30 minutes
const SSE_KEEPALIVE_MS = 25 * 1000;
const MAX_BODY_BYTES = 2 * 1024 * 1024; // 2 MB — same as stdio buffer cap

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "0:0:0:0:0:0:0:1"]);

// globalThis.crypto.randomUUID is stable on Deno (all versions) and Node
// (>=18.17). package.json declares engines.node >=18.0.0 — older Node 18
// builds without globalThis.crypto.randomUUID are out of support.
function makeSessionId() {
  return globalThis.crypto.randomUUID();
}

/**
 * Parse the BOJ_HTTP_AUTH_TOKENS CSV into a Set. Empty tokens are
 * dropped. Whitespace around each token is trimmed.
 */
function parseTokens(raw) {
  if (!raw) return new Set();
  return new Set(
    raw.split(",")
      .map((t) => t.trim())
      .filter((t) => t.length > 0),
  );
}

function isLoopback(host) {
  if (!host) return false;
  return LOOPBACK_HOSTS.has(host);
}

/**
 * Read configuration from environment. Returns a normalised opts object
 * used by createHttpServer. Throws on configurations that would expose
 * the bridge unsafely (auth=none + non-loopback bind).
 */
export function configFromEnv() {
  const port = parseInt(env.get("BOJ_HTTP_PORT") ?? `${DEFAULT_PORT}`, 10) || DEFAULT_PORT;
  const bind = env.get("BOJ_HTTP_BIND") ?? DEFAULT_BIND;
  const authMode = (env.get("BOJ_HTTP_AUTH") ?? (isLoopback(bind) ? "none" : "bearer")).toLowerCase();
  const tokens = parseTokens(env.get("BOJ_HTTP_AUTH_TOKENS"));

  if (authMode === "none" && !isLoopback(bind)) {
    throw new Error(
      `BOJ_HTTP_AUTH=none refuses to serve on non-loopback bind '${bind}'. ` +
      `Set BOJ_HTTP_AUTH=bearer (with BOJ_HTTP_AUTH_TOKENS) or bind to 127.0.0.1.`,
    );
  }
  if (authMode === "bearer" && tokens.size === 0) {
    throw new Error(
      "BOJ_HTTP_AUTH=bearer requires BOJ_HTTP_AUTH_TOKENS (CSV of accepted tokens).",
    );
  }
  if (authMode !== "none" && authMode !== "bearer") {
    throw new Error(`Unsupported BOJ_HTTP_AUTH='${authMode}'. PR1 supports 'none' and 'bearer'; mTLS/OIDC owed in PR2.`);
  }

  return { port, bind, authMode, tokens };
}

// =====================================================================
// Session manager
// =====================================================================

class SessionManager {
  constructor({ timeoutMs = SESSION_TIMEOUT_MS } = {}) {
    this.timeoutMs = timeoutMs;
    this.sessions = new Map();
  }

  create() {
    const id = makeSessionId();
    this.sessions.set(id, {
      id,
      createdMs: Date.now(),
      lastSeenMs: Date.now(),
      sseStreams: new Set(),
    });
    return id;
  }

  touch(id) {
    const s = this.sessions.get(id);
    if (!s) return false;
    s.lastSeenMs = Date.now();
    return true;
  }

  get(id) {
    return this.sessions.get(id);
  }

  delete(id) {
    const s = this.sessions.get(id);
    if (!s) return;
    for (const stream of s.sseStreams) {
      try { stream.close(); } catch { /* ignore */ }
    }
    this.sessions.delete(id);
  }

  /** Drop sessions idle beyond timeoutMs. Returns the count removed. */
  expireIdle(now = Date.now()) {
    let removed = 0;
    for (const [id, s] of this.sessions) {
      if (now - s.lastSeenMs > this.timeoutMs) {
        this.delete(id);
        removed += 1;
      }
    }
    return removed;
  }

  attachStream(id, stream) {
    const s = this.sessions.get(id);
    if (!s) return false;
    s.sseStreams.add(stream);
    return true;
  }

  detachStream(id, stream) {
    const s = this.sessions.get(id);
    if (!s) return;
    s.sseStreams.delete(stream);
  }

  /**
   * Fan out an event to every SSE stream for the given session. Used by
   * the ADR-0011 notifications path (wiring is owed; this is the seam).
   */
  emit(id, eventName, data) {
    const s = this.sessions.get(id);
    if (!s) return 0;
    let sent = 0;
    for (const stream of s.sseStreams) {
      try {
        stream.send(eventName, data);
        sent += 1;
      } catch {
        s.sseStreams.delete(stream);
      }
    }
    return sent;
  }
}

// =====================================================================
// Authentication
// =====================================================================

function checkAuth({ authMode, tokens, headerValue }) {
  if (authMode === "none") return { ok: true };
  if (authMode === "bearer") {
    if (!headerValue || typeof headerValue !== "string") {
      return { ok: false, code: 401, body: { error: "missing Authorization header" } };
    }
    const m = headerValue.match(/^Bearer\s+(.+)$/i);
    if (!m) return { ok: false, code: 401, body: { error: "expected 'Bearer <token>' Authorization header" } };
    if (!tokens.has(m[1].trim())) return { ok: false, code: 401, body: { error: "invalid bearer token" } };
    return { ok: true };
  }
  return { ok: false, code: 500, body: { error: `unsupported auth mode ${authMode}` } };
}

// =====================================================================
// Request handler (runtime-neutral)
// =====================================================================

const JSON_HEADERS = { "Content-Type": "application/json; charset=utf-8" };

/**
 * Build the JSON-RPC response object for a POST /mcp call. Returns
 * `{ status, headers, body }` where body is a JS object (caller
 * stringifies). Pure-ish: only side effect is session-table mutation.
 */
async function handleMcpPost({ rawBody, headers, sessions, auth }) {
  const sessionHeader = headers["mcp-session-id"];

  const authResult = checkAuth({
    authMode: auth.authMode,
    tokens: auth.tokens,
    headerValue: headers["authorization"],
  });
  if (!authResult.ok) {
    return { status: authResult.code, headers: JSON_HEADERS, body: authResult.body };
  }

  if (rawBody.length > MAX_BODY_BYTES) {
    return {
      status: 413,
      headers: JSON_HEADERS,
      body: { jsonrpc: "2.0", error: { code: -32600, message: "Message too large" } },
    };
  }

  let msg;
  try {
    msg = JSON.parse(rawBody);
  } catch {
    return {
      status: 400,
      headers: JSON_HEADERS,
      body: { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } },
    };
  }

  let sessionId = sessionHeader;
  if (msg.method === "initialize") {
    // initialize mints a new session — ignore any client-supplied id
    sessionId = sessions.create();
  } else if (sessionId) {
    if (!sessions.touch(sessionId)) {
      return {
        status: 404,
        headers: JSON_HEADERS,
        body: { jsonrpc: "2.0", id: msg.id ?? null, error: { code: -32001, message: "Unknown or expired Mcp-Session-Id" } },
      };
    }
  }

  const response = await dispatchMcpMessage(msg, { transport: "http", sessionId });

  // notifications/* and any other no-response method
  if (response === null) {
    const respHeaders = { ...JSON_HEADERS };
    if (sessionId) respHeaders["Mcp-Session-Id"] = sessionId;
    return { status: 202, headers: respHeaders, body: "" };
  }

  const respHeaders = { ...JSON_HEADERS };
  if (sessionId) respHeaders["Mcp-Session-Id"] = sessionId;
  return { status: 200, headers: respHeaders, body: response };
}

// =====================================================================
// SSE stream wrapper (runtime-neutral handle)
// =====================================================================

function makeSseDenoStream(controller) {
  const encoder = new TextEncoder();
  return {
    send(event, data) {
      const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
      controller.enqueue(encoder.encode(payload));
    },
    ping() {
      controller.enqueue(encoder.encode(`: keepalive\n\n`));
    },
    close() {
      try { controller.close(); } catch { /* idempotent */ }
    },
  };
}

function makeSseNodeStream(res) {
  return {
    send(event, data) {
      res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    },
    ping() {
      res.write(`: keepalive\n\n`);
    },
    close() {
      try { res.end(); } catch { /* idempotent */ }
    },
  };
}

// =====================================================================
// Server lifecycle — Deno path
// =====================================================================

async function startDeno({ port, bind, sessions, auth }) {
  const handler = async (req) => {
    const url = new URL(req.url);
    const headers = {};
    for (const [k, v] of req.headers) headers[k.toLowerCase()] = v;

    if (url.pathname === "/healthz" && req.method === "GET") {
      return new Response("ok\n", { status: 200, headers: { "Content-Type": "text/plain" } });
    }

    if (url.pathname !== "/mcp") {
      return new Response(JSON.stringify({ error: "not found" }), { status: 404, headers: JSON_HEADERS });
    }

    if (req.method === "POST") {
      const rawBody = await req.text();
      const out = await handleMcpPost({ rawBody, headers, sessions, auth });
      return new Response(
        typeof out.body === "string" ? out.body : JSON.stringify(out.body),
        { status: out.status, headers: out.headers },
      );
    }

    if (req.method === "GET") {
      const authResult = checkAuth({
        authMode: auth.authMode,
        tokens: auth.tokens,
        headerValue: headers["authorization"],
      });
      if (!authResult.ok) {
        return new Response(JSON.stringify(authResult.body), { status: authResult.code, headers: JSON_HEADERS });
      }
      const sessionId = headers["mcp-session-id"];
      if (!sessionId || !sessions.touch(sessionId)) {
        return new Response(JSON.stringify({ error: "missing or invalid Mcp-Session-Id" }), { status: 400, headers: JSON_HEADERS });
      }
      let stream;
      const body = new ReadableStream({
        start(controller) {
          stream = makeSseDenoStream(controller);
          sessions.attachStream(sessionId, stream);
          stream.send("ready", { sessionId });
          const keepalive = setInterval(() => {
            try { stream.ping(); } catch { clearInterval(keepalive); }
          }, SSE_KEEPALIVE_MS);
          stream._keepalive = keepalive;
        },
        cancel() {
          if (stream?._keepalive) clearInterval(stream._keepalive);
          sessions.detachStream(sessionId, stream);
        },
      });
      return new Response(body, {
        status: 200,
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          "Connection": "keep-alive",
          "Mcp-Session-Id": sessionId,
        },
      });
    }

    if (req.method === "DELETE") {
      const sessionId = headers["mcp-session-id"];
      if (sessionId) sessions.delete(sessionId);
      // 204 responses MUST NOT carry a body per RFC 9110; Deno's
      // Response constructor enforces null-body status codes.
      return new Response(null, { status: 204 });
    }

    return new Response(JSON.stringify({ error: "method not allowed" }), { status: 405, headers: JSON_HEADERS });
  };

  const server = Deno.serve({ port, hostname: bind, onListen: () => {} }, handler);
  info("MCP HTTP transport listening", { bind, port, authMode: auth.authMode });
  return {
    address: { host: bind, port },
    async stop() {
      try { await server.shutdown(); } catch { /* ignore */ }
    },
  };
}

// =====================================================================
// Server lifecycle — Node path
// =====================================================================

async function startNode({ port, bind, sessions, auth }) {
  const { createServer } = await import("node:http");

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, `http://${bind}`);
    const headers = {};
    for (const [k, v] of Object.entries(req.headers)) {
      headers[k.toLowerCase()] = Array.isArray(v) ? v.join(",") : v;
    }

    if (url.pathname === "/healthz" && req.method === "GET") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("ok\n");
      return;
    }

    if (url.pathname !== "/mcp") {
      res.writeHead(404, JSON_HEADERS);
      res.end(JSON.stringify({ error: "not found" }));
      return;
    }

    if (req.method === "POST") {
      const chunks = [];
      let total = 0;
      let oversized = false;
      for await (const chunk of req) {
        total += chunk.length;
        if (total > MAX_BODY_BYTES) { oversized = true; break; }
        chunks.push(chunk);
      }
      if (oversized) {
        res.writeHead(413, JSON_HEADERS);
        res.end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32600, message: "Message too large" } }));
        return;
      }
      const rawBody = Buffer.concat(chunks).toString("utf8");
      const out = await handleMcpPost({ rawBody, headers, sessions, auth });
      res.writeHead(out.status, out.headers);
      res.end(typeof out.body === "string" ? out.body : JSON.stringify(out.body));
      return;
    }

    if (req.method === "GET") {
      const authResult = checkAuth({
        authMode: auth.authMode,
        tokens: auth.tokens,
        headerValue: headers["authorization"],
      });
      if (!authResult.ok) {
        res.writeHead(authResult.code, JSON_HEADERS);
        res.end(JSON.stringify(authResult.body));
        return;
      }
      const sessionId = headers["mcp-session-id"];
      if (!sessionId || !sessions.touch(sessionId)) {
        res.writeHead(400, JSON_HEADERS);
        res.end(JSON.stringify({ error: "missing or invalid Mcp-Session-Id" }));
        return;
      }
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        "Connection": "keep-alive",
        "Mcp-Session-Id": sessionId,
      });
      const stream = makeSseNodeStream(res);
      sessions.attachStream(sessionId, stream);
      stream.send("ready", { sessionId });
      const keepalive = setInterval(() => {
        try { stream.ping(); } catch { clearInterval(keepalive); }
      }, SSE_KEEPALIVE_MS);
      req.on("close", () => {
        clearInterval(keepalive);
        sessions.detachStream(sessionId, stream);
      });
      return;
    }

    if (req.method === "DELETE") {
      const sessionId = headers["mcp-session-id"];
      if (sessionId) sessions.delete(sessionId);
      res.writeHead(204);
      res.end();
      return;
    }

    res.writeHead(405, JSON_HEADERS);
    res.end(JSON.stringify({ error: "method not allowed" }));
  });

  await new Promise((resolve, reject) => {
    const onError = (e) => { server.off("listening", onListen); reject(e); };
    const onListen = () => { server.off("error", onError); resolve(); };
    server.once("error", onError);
    server.once("listening", onListen);
    server.listen(port, bind);
  });

  info("MCP HTTP transport listening", { bind, port, authMode: auth.authMode });

  return {
    address: server.address(),
    async stop() {
      await new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

// =====================================================================
// Public entry point
// =====================================================================

/**
 * Start the HTTP transport. Returns a handle with `.stop()` for tests
 * and graceful shutdown. Errors during startup propagate.
 *
 * @param {object} [opts] override env-derived config; useful in tests
 * @param {number} [opts.port]
 * @param {string} [opts.bind]
 * @param {"none"|"bearer"} [opts.authMode]
 * @param {Iterable<string>} [opts.tokens]
 * @param {number} [opts.sessionTimeoutMs]
 * @returns {Promise<{ address: object, stop: () => Promise<void>, sessions: SessionManager }>}
 */
export async function startHttpTransport(opts = {}) {
  const envConfig = (() => {
    try { return configFromEnv(); } catch (e) {
      // tests pass opts directly; only fail if env was the source of config
      if (opts.port === undefined && opts.bind === undefined && opts.authMode === undefined) {
        throw e;
      }
      return null;
    }
  })();

  const port = opts.port ?? envConfig?.port ?? DEFAULT_PORT;
  const bind = opts.bind ?? envConfig?.bind ?? DEFAULT_BIND;
  const authMode = opts.authMode ?? envConfig?.authMode ?? (isLoopback(bind) ? "none" : "bearer");
  const tokens = opts.tokens ? new Set(opts.tokens) : (envConfig?.tokens ?? new Set());

  if (authMode === "none" && !isLoopback(bind)) {
    throw new Error(`Refusing to start: BOJ_HTTP_AUTH=none on non-loopback bind '${bind}'.`);
  }
  if (authMode === "bearer" && tokens.size === 0) {
    throw new Error("BOJ_HTTP_AUTH=bearer requires at least one token.");
  }

  const sessions = new SessionManager({ timeoutMs: opts.sessionTimeoutMs ?? SESSION_TIMEOUT_MS });

  const reaper = setInterval(() => {
    const removed = sessions.expireIdle();
    if (removed > 0) info("HTTP sessions expired", { count: removed });
  }, 60 * 1000);
  if (typeof reaper.unref === "function") reaper.unref();

  const auth = { authMode, tokens };

  let handle;
  if (isDeno) {
    handle = await startDeno({ port, bind, sessions, auth });
  } else {
    handle = await startNode({ port, bind, sessions, auth });
  }

  return {
    address: handle.address,
    sessions,
    async stop() {
      clearInterval(reaper);
      await handle.stop();
    },
  };
}

// Exposed for tests
export const _internals = {
  SessionManager,
  checkAuth,
  parseTokens,
  isLoopback,
  handleMcpPost,
  configFromEnv,
};
