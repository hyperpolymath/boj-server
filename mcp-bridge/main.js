#!/usr/bin/env -S deno run --allow-net --allow-env --allow-read
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — MCP transport bridge (stdio + HTTP per ADR-0013)
//
// Bridges the running BoJ REST API (port 7700) to the MCP JSON-RPC
// protocol so that Claude Code, Glama, and other MCP clients can
// discover and invoke BoJ cartridge tools. Two transports:
//
//   BOJ_TRANSPORT=stdio   default — read JSON-RPC from stdin, write to stdout
//   BOJ_TRANSPORT=http    listen on BOJ_HTTP_PORT (default 7780)
//   BOJ_TRANSPORT=both    run both simultaneously
//
// Usage:
//   deno run --allow-net --allow-env --allow-read mcp-bridge/main.js

import { env, stdout } from "./lib/runtime.js";
import { sanitizeErrorMessage } from "./lib/security.js";
import { dispatchMcpMessage } from "./lib/dispatcher.js";
import { info, error as logError } from "./lib/logger.js";
import * as otel from "./lib/otel.js";
import { startHttpTransport } from "./lib/http-transport.js";

const TRANSPORT = (env.get("BOJ_TRANSPORT") ?? "stdio").toLowerCase();

otel.init();

// ===================================================================
// stdio transport
// ===================================================================

const decoder = new TextDecoder();
let buffer = "";
const MAX_BUFFER_BYTES = 2 * 1_048_576; // 2 MB
const pendingMessages = [];

function send(obj) {
  stdout.writeSync(JSON.stringify(obj) + "\n");
}

function sendError(id, code, message) {
  send({ jsonrpc: "2.0", id, error: { code, message: sanitizeErrorMessage(message) } });
}

async function handleStdioLine(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    sendError(null, -32700, "Parse error");
    return;
  }
  const response = await dispatchMcpMessage(msg, { transport: "stdio" });
  if (response !== null) send(response);
}

function processChunk(chunk) {
  buffer += decoder.decode(chunk);
  if (buffer.length > MAX_BUFFER_BYTES) {
    sendError(null, -32600, "Message too large");
    buffer = "";
    return;
  }
  let boundary;
  while ((boundary = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, boundary).trim();
    buffer = buffer.slice(boundary + 1);
    if (line.length > 0) {
      const p = handleStdioLine(line).catch(() => {});
      pendingMessages.push(p);
    }
  }
}

async function runStdio() {
  if (typeof Deno !== "undefined") {
    for await (const chunk of Deno.stdin.readable) processChunk(chunk);
  } else {
    // @ts-ignore: process is global in Node
    for await (const chunk of process.stdin) processChunk(chunk);
  }
  await Promise.allSettled(pendingMessages);
}

// ===================================================================
// HTTP transport
// ===================================================================

async function runHttp() {
  const handle = await startHttpTransport();
  await new Promise((resolve) => {
    const stop = async () => {
      info("MCP HTTP transport shutting down");
      await handle.stop();
      resolve();
    };
    if (typeof Deno !== "undefined") {
      Deno.addSignalListener("SIGINT", stop);
      try { Deno.addSignalListener("SIGTERM", stop); } catch { /* not supported on all platforms */ }
    } else {
      // @ts-ignore: process is global in Node
      process.on("SIGINT", stop);
      // @ts-ignore
      process.on("SIGTERM", stop);
    }
  });
}

// ===================================================================
// Main
// ===================================================================

async function main() {
  if (TRANSPORT === "stdio") {
    await runStdio();
  } else if (TRANSPORT === "http") {
    await runHttp();
  } else if (TRANSPORT === "both") {
    await Promise.all([runStdio(), runHttp()]);
  } else {
    logError("Unknown BOJ_TRANSPORT", { value: TRANSPORT, supported: ["stdio", "http", "both"] });
    if (typeof Deno !== "undefined") Deno.exit(2);
    // @ts-ignore: process is global in Node
    else process.exit(2);
  }
}

try {
  await main();
} catch (e) {
  logError("MCP bridge fatal", { error: e?.message ?? String(e) });
  if (typeof Deno !== "undefined") Deno.exit(1);
  // @ts-ignore: process is global in Node
  else process.exit(1);
}

if (typeof Deno !== "undefined") Deno.exit(0);
// @ts-ignore: process is global in Node
else process.exit(0);
