// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// dap-mcp/mod.js -- Generic Debug Adapter Protocol (DAP) gateway cartridge.
//
// Manages persistent DAP adapter subprocesses communicating over JSON-RPC 2.0
// with Content-Length framing (stdio transport, same as LSP).  Each session
// runs one adapter subprocess that stays alive until dap_stop is called.
//
// Session lifecycle:
//   dap_start → dap_initialize → dap_launch | dap_attach
//     → dap_set_breakpoints → dap_continue | dap_step_over | dap_step_in | dap_step_out
//     → dap_stack_trace → dap_variables
//     → dap_stop
//
// Auth: None required — local subprocess.
//
// Usage: import { handleTool } from "./mod.js";

// ---------------------------------------------------------------------------
// JsonRpcSession — persistent subprocess + JSON-RPC 2.0 / Content-Length framing
// (DAP uses the same transport as LSP; events replace LSP notifications here)
// ---------------------------------------------------------------------------

class JsonRpcSession {
  /** @type {Deno.ChildProcess} */ #proc;
  /** @type {Map<number, {resolve: Function, reject: Function, timer: number}>} */
  #pending = new Map();
  /** @type {Array<object>} */ #events = [];
  #nextSeq = 1;
  #buf = new Uint8Array(0);
  #closed = false;
  static #MAX_EVENTS = 200;
  static #REQUEST_TIMEOUT_MS = 30_000;

  constructor(proc) {
    this.#proc = proc;
    this.#drainLoop();
  }

  // -- Public API -----------------------------------------------------------

  /** Send a DAP request and await the response body. */
  request(command, args) {
    return new Promise((resolve, reject) => {
      if (this.#closed) { reject(new Error("session closed")); return; }
      const seq = this.#nextSeq++;
      const msg = JSON.stringify({ seq, type: "request", command, arguments: args ?? {} });
      const header = `Content-Length: ${new TextEncoder().encode(msg).byteLength}\r\n\r\n`;
      const timer = setTimeout(() => {
        this.#pending.delete(seq);
        reject(new Error(`DAP request '${command}' timed out after ${JsonRpcSession.#REQUEST_TIMEOUT_MS}ms`));
      }, JsonRpcSession.#REQUEST_TIMEOUT_MS);
      this.#pending.set(seq, { resolve, reject, timer });
      this.#write(header + msg);
    });
  }

  /** Return buffered events (DAP 'event' messages), optionally filtered by event name. */
  getEvents(event) {
    return event
      ? this.#events.filter(e => e.event === event)
      : [...this.#events];
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

  // -- Private helpers ------------------------------------------------------

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

      if (msg.type === "response") {
        const entry = this.#pending.get(msg.request_seq);
        if (entry) {
          clearTimeout(entry.timer);
          this.#pending.delete(msg.request_seq);
          if (!msg.success) entry.reject(Object.assign(new Error(msg.message ?? "DAP error"), { body: msg.body }));
          else entry.resolve(msg.body ?? {});
        }
      } else if (msg.type === "event") {
        if (this.#events.length >= JsonRpcSession.#MAX_EVENTS) this.#events.shift();
        this.#events.push(msg);
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
  return `dap_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
}

function getSession(session_id) {
  const entry = SESSIONS.get(session_id);
  if (!entry) throw Object.assign(new Error(`Unknown DAP session: ${session_id}`), { status: 404 });
  return entry;
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // -- dap_start -----------------------------------------------------------
    case "dap_start": {
      const { command, args: extraArgs = [], cwd } = args;
      if (!command) return { status: 400, data: { error: "command is required" } };

      const cmdParts = command.trim().split(/\s+/);
      const proc = new Deno.Command(cmdParts[0], {
        args: [...cmdParts.slice(1), ...extraArgs],
        cwd: cwd,
        stdin: "piped",
        stdout: "piped",
        stderr: "null",
      }).spawn();

      const session = new JsonRpcSession(proc);
      const session_id = newSessionId();
      SESSIONS.set(session_id, {
        session,
        meta: { command, initialized: false, launched: false },
      });
      return { status: 200, data: { session_id, message: `DAP adapter started: ${command}` } };
    }

    // -- dap_initialize ------------------------------------------------------
    case "dap_initialize": {
      const { session_id, adapter_id, locale = "en-GB" } = args;
      const { session, meta } = getSession(session_id);
      const body = await session.request("initialize", {
        adapterID: adapter_id,
        clientID: "boj-dap-mcp",
        clientName: "BoJ DAP MCP",
        locale,
        linesStartAt1: true,
        columnsStartAt1: true,
        pathFormat: "path",
        supportsVariableType: true,
        supportsVariablePaging: true,
        supportsRunInTerminalRequest: false,
        supportsProgressReporting: false,
      });
      meta.initialized = true;
      meta.capabilities = body;
      return { status: 200, data: { capabilities: body } };
    }

    // -- dap_launch ----------------------------------------------------------
    case "dap_launch": {
      const { session_id, program, args: progArgs = [], cwd, env, stop_on_entry = false } = args;
      const { session, meta } = getSession(session_id);
      const body = await session.request("launch", {
        program,
        args: progArgs,
        cwd,
        env,
        stopOnEntry: stop_on_entry,
        noDebug: false,
      });
      meta.launched = true;
      return { status: 200, data: body };
    }

    // -- dap_attach ----------------------------------------------------------
    case "dap_attach": {
      const { session_id, pid, host, port } = args;
      const { session, meta } = getSession(session_id);
      const attachArgs = {};
      if (pid != null) attachArgs.pid = pid;
      if (host) attachArgs.host = host;
      if (port != null) attachArgs.port = port;
      const body = await session.request("attach", attachArgs);
      meta.launched = true;
      return { status: 200, data: body };
    }

    // -- dap_set_breakpoints -------------------------------------------------
    case "dap_set_breakpoints": {
      const { session_id, source_path, lines, conditions = [] } = args;
      const { session } = getSession(session_id);
      const breakpoints = lines.map((line, i) => {
        const bp = { line };
        if (conditions[i]) bp.condition = conditions[i];
        return bp;
      });
      const body = await session.request("setBreakpoints", {
        source: { path: source_path },
        breakpoints,
      });
      return { status: 200, data: { breakpoints: body.breakpoints ?? [] } };
    }

    // -- dap_continue --------------------------------------------------------
    case "dap_continue": {
      const { session_id, thread_id = 0 } = args;
      const { session } = getSession(session_id);
      const body = await session.request("continue", { threadId: thread_id });
      return { status: 200, data: body };
    }

    // -- dap_step_over -------------------------------------------------------
    case "dap_step_over": {
      const { session_id, thread_id, granularity = "statement" } = args;
      const { session } = getSession(session_id);
      const body = await session.request("next", { threadId: thread_id, granularity });
      return { status: 200, data: body };
    }

    // -- dap_step_in ---------------------------------------------------------
    case "dap_step_in": {
      const { session_id, thread_id } = args;
      const { session } = getSession(session_id);
      const body = await session.request("stepIn", { threadId: thread_id });
      return { status: 200, data: body };
    }

    // -- dap_step_out --------------------------------------------------------
    case "dap_step_out": {
      const { session_id, thread_id } = args;
      const { session } = getSession(session_id);
      const body = await session.request("stepOut", { threadId: thread_id });
      return { status: 200, data: body };
    }

    // -- dap_stack_trace -----------------------------------------------------
    case "dap_stack_trace": {
      const { session_id, thread_id, start_frame = 0, levels = 20 } = args;
      const { session } = getSession(session_id);
      const body = await session.request("stackTrace", {
        threadId: thread_id,
        startFrame: start_frame,
        levels,
      });
      return { status: 200, data: { frames: body.stackFrames ?? [], total: body.totalFrames ?? null } };
    }

    // -- dap_variables -------------------------------------------------------
    case "dap_variables": {
      const { session_id, variables_reference, filter, start, count } = args;
      const { session } = getSession(session_id);
      const req = { variablesReference: variables_reference };
      if (filter) req.filter = filter;
      if (start != null) req.start = start;
      if (count != null) req.count = count;
      const body = await session.request("variables", req);
      return { status: 200, data: { variables: body.variables ?? [] } };
    }

    // -- dap_stop ------------------------------------------------------------
    case "dap_stop": {
      const { session_id, terminate_debuggee = true } = args;
      const entry = SESSIONS.get(session_id);
      if (!entry) return { status: 404, data: { error: `Unknown session: ${session_id}` } };
      const { session } = entry;
      try { await session.request("disconnect", { terminateDebuggee: terminate_debuggee }); } catch { /* ignore */ }
      await session.close();
      SESSIONS.delete(session_id);
      return { status: 200, data: { stopped: session_id } };
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
