// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// lsp-mcp/mod.js -- Generic LSP 3.17 gateway cartridge implementation.
//
// Manages persistent LSP server subprocesses communicating over JSON-RPC 2.0
// with Content-Length framing (stdio transport).  Each session runs one server
// subprocess that stays alive until lsp_stop is called.  Up to 64 concurrent
// sessions are supported.
//
// Session lifecycle:
//   lsp_start → lsp_initialize → (lsp_open / lsp_change / lsp_hover / …) → lsp_stop
//
// Auth: None required — local subprocess.
//
// Usage: import { handleTool } from "./mod.js";

// ---------------------------------------------------------------------------
// JsonRpcSession — persistent subprocess + JSON-RPC 2.0 over stdio (LSP framing)
// ---------------------------------------------------------------------------

class JsonRpcSession {
  /** @type {Deno.ChildProcess} */  #proc;
  /** @type {Map<number, {resolve: Function, reject: Function, timer: number}>} */
  #pending = new Map();
  /** @type {Array<object>} */ #notifications = [];
  #nextId = 1;
  #buf = new Uint8Array(0);
  #closed = false;
  static #MAX_NOTIFICATIONS = 100;
  static #REQUEST_TIMEOUT_MS = 30_000;

  constructor(proc) {
    this.#proc = proc;
    this.#drainLoop();
  }

  // -- Public API -----------------------------------------------------------

  /** Send a JSON-RPC request and await the result (or error). */
  request(method, params) {
    return new Promise((resolve, reject) => {
      if (this.#closed) { reject(new Error("session closed")); return; }
      const id = this.#nextId++;
      const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });
      const header = `Content-Length: ${new TextEncoder().encode(msg).byteLength}\r\n\r\n`;
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`Request ${method} timed out after ${JsonRpcSession.#REQUEST_TIMEOUT_MS}ms`));
      }, JsonRpcSession.#REQUEST_TIMEOUT_MS);
      this.#pending.set(id, { resolve, reject, timer });
      this.#write(header + msg);
    });
  }

  /** Send a JSON-RPC notification (no id, no response expected). */
  notify(method, params) {
    if (this.#closed) return;
    const msg = JSON.stringify({ jsonrpc: "2.0", method, params });
    const header = `Content-Length: ${new TextEncoder().encode(msg).byteLength}\r\n\r\n`;
    this.#write(header + msg);
  }

  /** Return buffered notifications, optionally filtered by method. */
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
        // Append to buffer
        const combined = new Uint8Array(this.#buf.length + value.length);
        combined.set(this.#buf);
        combined.set(value, this.#buf.length);
        this.#buf = combined;
        // Parse as many complete messages as possible
        this.#parseMessages(dec);
      }
    } catch { /* read error — session is dying */ }
    this.#closed = true;
  }

  #parseMessages(dec) {
    while (true) {
      const text = dec.decode(this.#buf);
      // Find Content-Length header
      const sep = text.indexOf("\r\n\r\n");
      if (sep === -1) return;
      const headerSection = text.slice(0, sep);
      const match = /Content-Length:\s*(\d+)/i.exec(headerSection);
      if (!match) { this.#buf = new Uint8Array(0); return; } // malformed
      const bodyLen = parseInt(match[1], 10);
      const headerBytes = new TextEncoder().encode(headerSection + "\r\n\r\n").byteLength;
      if (this.#buf.length < headerBytes + bodyLen) return; // incomplete
      const bodyBytes = this.#buf.slice(headerBytes, headerBytes + bodyLen);
      this.#buf = this.#buf.slice(headerBytes + bodyLen);
      let msg;
      try { msg = JSON.parse(dec.decode(bodyBytes)); } catch { continue; }
      if ("id" in msg && msg.id !== null) {
        // Response
        const entry = this.#pending.get(msg.id);
        if (entry) {
          clearTimeout(entry.timer);
          this.#pending.delete(msg.id);
          if (msg.error) entry.reject(Object.assign(new Error(msg.error.message ?? "RPC error"), { code: msg.error.code }));
          else entry.resolve(msg.result);
        }
      } else if ("method" in msg) {
        // Notification
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
  return `lsp_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
}

function getSession(session_id) {
  const entry = SESSIONS.get(session_id);
  if (!entry) throw Object.assign(new Error(`Unknown LSP session: ${session_id}`), { status: 404 });
  return entry;
}

// Permanent pinned toolchain presets (presets.json, co-located). Lets callers
// pass {preset:"rust"} instead of re-specifying the rust-analyzer path every
// time. Loaded once, lazily; missing/invalid file degrades to "no presets".
let _presets = null;
async function loadPresets() {
  if (_presets) return _presets;
  try {
    const txt = await Deno.readTextFile(new URL("./presets.json", import.meta.url));
    _presets = JSON.parse(txt).presets ?? {};
  } catch {
    _presets = {};
  }
  return _presets;
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // -- lsp_start -----------------------------------------------------------
    case "lsp_start": {
      let { command, preset, args: extraArgs = [], workspace_root } = args;

      // Resolve a permanent pinned preset (e.g. "rust" → rust-analyzer) so
      // callers never re-assemble the toolchain. Explicit `command` still
      // wins and stays fully backward-compatible.
      if (!command && preset) {
        const presets = await loadPresets();
        const p = presets[preset];
        if (!p) {
          return { status: 400, data: { error: `Unknown preset '${preset}'. Available: ${Object.keys(presets).join(", ") || "(none)"}` } };
        }
        command = p.command;
        if (Array.isArray(p.args) && p.args.length) extraArgs = [...p.args, ...extraArgs];
      }
      if (!command) return { status: 400, data: { error: "command or preset is required" } };

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
        meta: { command, workspace_root: workspace_root ?? null, initialized: false, openDocs: new Set() },
      });
      return { status: 200, data: { session_id, message: `LSP server started: ${command}` } };
    }

    // -- lsp_initialize ------------------------------------------------------
    case "lsp_initialize": {
      const { session_id, root_uri, client_name = "boj-lsp-mcp" } = args;
      const { session, meta } = getSession(session_id);
      const result = await session.request("initialize", {
        processId: null,
        clientInfo: { name: client_name, version: "0.1.0" },
        rootUri: root_uri,
        capabilities: {
          textDocument: {
            synchronization: { dynamicRegistration: false, willSave: false, didSave: false, willSaveWaitUntil: false },
            hover: { dynamicRegistration: false, contentFormat: ["plaintext", "markdown"] },
            completion: { dynamicRegistration: false, completionItem: { snippetSupport: false } },
            definition: { dynamicRegistration: false },
            references: { dynamicRegistration: false },
            publishDiagnostics: { relatedInformation: true },
            formatting: { dynamicRegistration: false },
          },
          workspace: { workspaceFolders: true },
        },
      });
      session.notify("initialized", {});
      meta.initialized = true;
      meta.capabilities = result.capabilities;
      return { status: 200, data: { capabilities: result.capabilities, serverInfo: result.serverInfo ?? null } };
    }

    // -- lsp_open ------------------------------------------------------------
    case "lsp_open": {
      const { session_id, uri, language_id, text } = args;
      const { session, meta } = getSession(session_id);
      session.notify("textDocument/didOpen", {
        textDocument: { uri, languageId: language_id, version: 1, text },
      });
      meta.openDocs.add(uri);
      return { status: 200, data: { opened: uri } };
    }

    // -- lsp_change ----------------------------------------------------------
    case "lsp_change": {
      const { session_id, uri, text, version = 2 } = args;
      const { session } = getSession(session_id);
      session.notify("textDocument/didChange", {
        textDocument: { uri, version },
        contentChanges: [{ text }],
      });
      return { status: 200, data: { changed: uri, version } };
    }

    // -- lsp_close -----------------------------------------------------------
    case "lsp_close": {
      const { session_id, uri } = args;
      const { session, meta } = getSession(session_id);
      session.notify("textDocument/didClose", { textDocument: { uri } });
      meta.openDocs.delete(uri);
      return { status: 200, data: { closed: uri } };
    }

    // -- lsp_hover -----------------------------------------------------------
    case "lsp_hover": {
      const { session_id, uri, line, col } = args;
      const { session } = getSession(session_id);
      const result = await session.request("textDocument/hover", {
        textDocument: { uri },
        position: { line, character: col },
      });
      return { status: 200, data: result ?? { contents: null } };
    }

    // -- lsp_complete --------------------------------------------------------
    case "lsp_complete": {
      const { session_id, uri, line, col, trigger_char } = args;
      const { session } = getSession(session_id);
      const context = trigger_char
        ? { triggerKind: 2, triggerCharacter: trigger_char }
        : { triggerKind: 1 };
      const result = await session.request("textDocument/completion", {
        textDocument: { uri },
        position: { line, character: col },
        context,
      });
      // result may be CompletionList or CompletionItem[]
      const items = Array.isArray(result) ? result : (result?.items ?? []);
      return { status: 200, data: { items, count: items.length } };
    }

    // -- lsp_goto_def --------------------------------------------------------
    case "lsp_goto_def": {
      const { session_id, uri, line, col } = args;
      const { session } = getSession(session_id);
      const result = await session.request("textDocument/definition", {
        textDocument: { uri },
        position: { line, character: col },
      });
      return { status: 200, data: { locations: Array.isArray(result) ? result : (result ? [result] : []) } };
    }

    // -- lsp_references ------------------------------------------------------
    case "lsp_references": {
      const { session_id, uri, line, col, include_declaration = true } = args;
      const { session } = getSession(session_id);
      const result = await session.request("textDocument/references", {
        textDocument: { uri },
        position: { line, character: col },
        context: { includeDeclaration: include_declaration },
      });
      return { status: 200, data: { locations: result ?? [] } };
    }

    // -- lsp_diagnostics -----------------------------------------------------
    case "lsp_diagnostics": {
      const { session_id, uri } = args;
      const { session } = getSession(session_id);
      const notifications = session.getNotifications("textDocument/publishDiagnostics");
      let result;
      if (uri) {
        const latest = notifications.filter(n => n.params?.uri === uri).at(-1);
        result = latest ? { [uri]: latest.params.diagnostics } : { [uri]: [] };
      } else {
        // Collect latest per-uri
        const map = {};
        for (const n of notifications) {
          if (n.params?.uri) map[n.params.uri] = n.params.diagnostics;
        }
        result = map;
      }
      return { status: 200, data: result };
    }

    // -- lsp_format ----------------------------------------------------------
    case "lsp_format": {
      const { session_id, uri, tab_size = 2, insert_spaces = true } = args;
      const { session } = getSession(session_id);
      const result = await session.request("textDocument/formatting", {
        textDocument: { uri },
        options: { tabSize: tab_size, insertSpaces: insert_spaces },
      });
      return { status: 200, data: { edits: result ?? [] } };
    }

    // -- lsp_stop ------------------------------------------------------------
    case "lsp_stop": {
      const { session_id } = args;
      const entry = SESSIONS.get(session_id);
      if (!entry) return { status: 404, data: { error: `Unknown session: ${session_id}` } };
      const { session } = entry;
      try { await session.request("shutdown", null); } catch { /* ignore if server died */ }
      session.notify("exit", null);
      await session.close();
      SESSIONS.delete(session_id);
      return { status: 200, data: { stopped: session_id } };
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
