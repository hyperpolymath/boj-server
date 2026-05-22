// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// bsp-mcp/mod.js -- Generic Build Server Protocol (BSP 2.x) gateway cartridge.
//
// Manages persistent BSP server subprocesses communicating over JSON-RPC 2.0
// with Content-Length framing (stdio transport, same as LSP).  Each session
// runs one server subprocess that stays alive until bsp_stop is called.
//
// Session lifecycle:
//   bsp_start → bsp_initialize → bsp_targets
//     → bsp_compile | bsp_test | bsp_run | bsp_clean
//     → bsp_diagnostics (reads buffered build/publishDiagnostics notifications)
//     → bsp_stop
//
// Auth: None required — local subprocess.
//
// Usage: import { handleTool } from "./mod.js";

// ---------------------------------------------------------------------------
// JsonRpcSession — persistent subprocess + JSON-RPC 2.0 / Content-Length framing
// ---------------------------------------------------------------------------

class JsonRpcSession {
  /** @type {Deno.ChildProcess} */ #proc;
  /** @type {Map<number, {resolve: Function, reject: Function, timer: number}>} */
  #pending = new Map();
  /** @type {Array<object>} */ #notifications = [];
  #nextId = 1;
  #buf = new Uint8Array(0);
  #closed = false;
  static #MAX_NOTIFICATIONS = 200;
  static #REQUEST_TIMEOUT_MS = 60_000; // BSP builds can be slow

  constructor(proc) {
    this.#proc = proc;
    this.#drainLoop();
  }

  request(method, params) {
    return new Promise((resolve, reject) => {
      if (this.#closed) { reject(new Error("session closed")); return; }
      const id = this.#nextId++;
      const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });
      const header = `Content-Length: ${new TextEncoder().encode(msg).byteLength}\r\n\r\n`;
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`BSP request '${method}' timed out after ${JsonRpcSession.#REQUEST_TIMEOUT_MS}ms`));
      }, JsonRpcSession.#REQUEST_TIMEOUT_MS);
      this.#pending.set(id, { resolve, reject, timer });
      this.#write(header + msg);
    });
  }

  notify(method, params) {
    if (this.#closed) return;
    const msg = JSON.stringify({ jsonrpc: "2.0", method, params });
    const header = `Content-Length: ${new TextEncoder().encode(msg).byteLength}\r\n\r\n`;
    this.#write(header + msg);
  }

  getNotifications(method) {
    return method
      ? this.#notifications.filter(n => n.method === method)
      : [...this.#notifications];
  }

  async close() {
    if (this.#closed) return;
    this.#closed = true;
    for (const { reject, timer } of this.#pending.values()) {
      clearTimeout(timer);
      reject(new Error("session closed"));
    }
    this.#pending.clear();
    try { this.#proc.stdin.close(); } catch { /* ignore */ }
    try { await this.#proc.status; } catch { /* ignore */ }
  }

  #write(text) {
    try {
      const writer = this.#proc.stdin.getWriter();
      writer.write(new TextEncoder().encode(text)).finally(() => writer.releaseLock());
    } catch { /* process may have died */ }
  }

  async #drainLoop() {
    const reader = this.#proc.stdout.getReader();
    const dec = new TextDecoder();
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        const combined = new Uint8Array(this.#buf.length + value.length);
        combined.set(this.#buf);
        combined.set(value, this.#buf.length);
        this.#buf = combined;
        this.#parseMessages(dec);
      }
    } catch { /* read error */ }
    this.#closed = true;
  }

  #parseMessages(dec) {
    while (true) {
      const text = dec.decode(this.#buf);
      const sep = text.indexOf("\r\n\r\n");
      if (sep === -1) return;
      const headerSection = text.slice(0, sep);
      const match = /Content-Length:\s*(\d+)/i.exec(headerSection);
      if (!match) { this.#buf = new Uint8Array(0); return; }
      const bodyLen = parseInt(match[1], 10);
      const headerBytes = new TextEncoder().encode(headerSection + "\r\n\r\n").byteLength;
      if (this.#buf.length < headerBytes + bodyLen) return;
      const bodyBytes = this.#buf.slice(headerBytes, headerBytes + bodyLen);
      this.#buf = this.#buf.slice(headerBytes + bodyLen);
      let msg;
      try { msg = JSON.parse(dec.decode(bodyBytes)); } catch { continue; }
      if ("id" in msg && msg.id !== null) {
        const entry = this.#pending.get(msg.id);
        if (entry) {
          clearTimeout(entry.timer);
          this.#pending.delete(msg.id);
          if (msg.error) entry.reject(Object.assign(new Error(msg.error.message ?? "RPC error"), { code: msg.error.code }));
          else entry.resolve(msg.result);
        }
      } else if ("method" in msg) {
        if (this.#notifications.length >= JsonRpcSession.#MAX_NOTIFICATIONS) this.#notifications.shift();
        this.#notifications.push(msg);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Session registry
// ---------------------------------------------------------------------------

/** @type {Map<string, {session: JsonRpcSession, meta: object}>} */
const SESSIONS = new Map();

function newSessionId() {
  return `bsp_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
}

function getSession(session_id) {
  const entry = SESSIONS.get(session_id);
  if (!entry) throw Object.assign(new Error(`Unknown BSP session: ${session_id}`), { status: 404 });
  return entry;
}

// Build target URI helper — wraps a plain string in a BSP BuildTargetIdentifier
function targetId(uri) { return { uri }; }

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // -- bsp_start -----------------------------------------------------------
    case "bsp_start": {
      const { command, args: extraArgs = [], workspace_root } = args;
      if (!command) return { status: 400, data: { error: "command is required" } };

      const cmdParts = command.trim().split(/\s+/);
      const proc = new Deno.Command(cmdParts[0], {
        args: [...cmdParts.slice(1), ...extraArgs],
        cwd: workspace_root,
        stdin: "piped",
        stdout: "piped",
        stderr: "null",
      }).spawn();

      const session = new JsonRpcSession(proc);
      const session_id = newSessionId();
      SESSIONS.set(session_id, {
        session,
        meta: { command, workspace_root: workspace_root ?? null, initialized: false },
      });
      return { status: 200, data: { session_id, message: `BSP server started: ${command}` } };
    }

    // -- bsp_initialize ------------------------------------------------------
    case "bsp_initialize": {
      const {
        session_id,
        display_name = "boj-bsp-mcp",
        version = "0.1.0",
        bsp_version = "2.2.0",
      } = args;
      const { session, meta } = getSession(session_id);
      const result = await session.request("build/initialize", {
        displayName: display_name,
        version,
        bspVersion: bsp_version,
        rootUri: meta.workspace_root ? `file://${meta.workspace_root}` : null,
        capabilities: {
          languageIds: [],
        },
      });
      session.notify("build/initialized", {});
      meta.initialized = true;
      meta.capabilities = result.capabilities;
      return { status: 200, data: { capabilities: result.capabilities, displayName: result.displayName, version: result.version } };
    }

    // -- bsp_targets ---------------------------------------------------------
    case "bsp_targets": {
      const { session_id } = args;
      const { session } = getSession(session_id);
      const result = await session.request("workspace/buildTargets", {});
      return { status: 200, data: { targets: result.targets ?? [] } };
    }

    // -- bsp_compile ---------------------------------------------------------
    case "bsp_compile": {
      const { session_id, targets = [], origin_id } = args;
      const { session } = getSession(session_id);
      const req = { targets: targets.map(targetId) };
      if (origin_id) req.originId = origin_id;
      const result = await session.request("buildTarget/compile", req);
      // Collect any diagnostics published during the build
      const diags = session.getNotifications("build/publishDiagnostics");
      return { status: 200, data: { result, diagnostics: diags.map(n => n.params) } };
    }

    // -- bsp_test ------------------------------------------------------------
    case "bsp_test": {
      const { session_id, targets = [], arguments: testArgs = [], origin_id } = args;
      const { session } = getSession(session_id);
      const req = { targets: targets.map(targetId), arguments: testArgs };
      if (origin_id) req.originId = origin_id;
      const result = await session.request("buildTarget/test", req);
      return { status: 200, data: result };
    }

    // -- bsp_run -------------------------------------------------------------
    case "bsp_run": {
      const { session_id, target, arguments: runArgs = [], environment_variables } = args;
      const { session } = getSession(session_id);
      const req = { target: targetId(target), arguments: runArgs };
      if (environment_variables) req.environmentVariables = environment_variables;
      const result = await session.request("buildTarget/run", req);
      // Capture any output events
      const outputEvents = session.getNotifications("build/logMessage");
      return { status: 200, data: { result, output: outputEvents.map(n => n.params?.message).filter(Boolean) } };
    }

    // -- bsp_clean -----------------------------------------------------------
    case "bsp_clean": {
      const { session_id, targets = [] } = args;
      const { session } = getSession(session_id);
      const result = await session.request("workspace/cleanCache", {
        targets: targets.map(targetId),
      });
      return { status: 200, data: result };
    }

    // -- bsp_diagnostics -----------------------------------------------------
    case "bsp_diagnostics": {
      const { session_id, target } = args;
      const { session } = getSession(session_id);
      const notifications = session.getNotifications("build/publishDiagnostics");
      let result;
      if (target) {
        const matching = notifications.filter(n => n.params?.buildTarget?.uri === target);
        result = matching.map(n => n.params);
      } else {
        result = notifications.map(n => n.params);
      }
      return { status: 200, data: { diagnostics: result } };
    }

    // -- bsp_stop ------------------------------------------------------------
    case "bsp_stop": {
      const { session_id } = args;
      const entry = SESSIONS.get(session_id);
      if (!entry) return { status: 404, data: { error: `Unknown session: ${session_id}` } };
      const { session } = entry;
      try { await session.request("build/shutdown", null); } catch { /* ignore */ }
      session.notify("build/exit", null);
      await session.close();
      SESSIONS.delete(session_id);
      return { status: 200, data: { stopped: session_id } };
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
