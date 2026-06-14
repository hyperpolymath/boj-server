// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — bridge boot smoke (runtime portability gate)
//
// Spawns the MCP bridge (`main.js`) under a given runtime command,
// performs a real JSON-RPC handshake over stdio (initialize →
// notifications/initialized → tools/list), and asserts the bridge
// answers with serverInfo and a non-empty tool list, then exits 0
// when stdin closes.
//
// The unit suite (dispatch_test.js etc.) imports the lib/ modules but
// never boots main.js itself — so a runtime-specific leak in the boot
// path (e.g. a bare `Deno.*` reference under Node/Bun, the PR #211
// bug class) would pass units and still break `npx`/`bun main.js`.
// This smoke closes that gap. No REST backend is required: initialize
// and tools/list are bridge-local (offline manifest).
//
// Usage (orchestrator always runs under Node; subject runtime varies).
// The deno leg uses main.js's own scoped grant, not -A, so the smoke
// exercises the exact permission set a real install uses:
//   node mcp-bridge/tests/boot_smoke.js node mcp-bridge/main.js
//   node mcp-bridge/tests/boot_smoke.js deno run --allow-net --allow-env --allow-read mcp-bridge/main.js
//   node mcp-bridge/tests/boot_smoke.js bun mcp-bridge/main.js

import { spawn } from "node:child_process";
import process from "node:process";

const TIMEOUT_MS = 30_000;

const argv = process.argv.slice(2);
if (argv.length === 0) {
  console.error("usage: node boot_smoke.js <runtime command...>");
  process.exit(2);
}

const requests = [
  {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "boot-smoke", version: "0.0.0" },
    },
  },
  { jsonrpc: "2.0", method: "notifications/initialized" },
  { jsonrpc: "2.0", id: 2, method: "tools/list" },
];

const child = spawn(argv[0], argv.slice(1), {
  stdio: ["pipe", "pipe", "pipe"],
  env: { ...process.env, BOJ_TRANSPORT: "stdio" },
});

let stdout = "";
let stderr = "";
child.stdout.on("data", (d) => (stdout += d));
child.stderr.on("data", (d) => (stderr += d));
child.stdin.on("error", (e) => (stderr += `stdin error: ${e.message}\n`));

const killTimer = setTimeout(() => {
  console.error(`FAIL: bridge did not exit within ${TIMEOUT_MS}ms`);
  child.kill("SIGKILL");
}, TIMEOUT_MS);

const payload = requests.map((r) => JSON.stringify(r)).join("\n") + "\n";
child.once("spawn", () => {
  child.stdin.end(payload);
});

child.on("close", (code) => {
  clearTimeout(killTimer);
  const fail = (msg) => {
    console.error(`FAIL: ${msg}`);
    console.error(`--- subject: ${argv.join(" ")}`);
    console.error(`--- exit code: ${code}`);
    console.error(`--- stdout ---\n${stdout}`);
    console.error(`--- stderr ---\n${stderr}`);
    process.exit(1);
  };

  if (code !== 0) return fail(`expected exit 0, got ${code}`);

  const responses = [];
  for (const line of stdout.split("\n")) {
    const s = line.trim();
    if (!s.startsWith("{")) continue;
    try {
      responses.push(JSON.parse(s));
    } catch {
      return fail(`non-JSON line on stdout: ${s.slice(0, 200)}`);
    }
  }

  const init = responses.find((r) => r.id === 1);
  if (!init?.result?.serverInfo?.name) {
    return fail("no initialize response with result.serverInfo.name");
  }
  const tools = responses.find((r) => r.id === 2);
  if (!Array.isArray(tools?.result?.tools) || tools.result.tools.length === 0) {
    return fail("no tools/list response with a non-empty result.tools");
  }

  console.log(
    `OK: ${argv[0]} boot smoke — serverInfo.name=${init.result.serverInfo.name}, ` +
      `tools=${tools.result.tools.length}, exit=0`,
  );
});
