// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Long-lived Deno pool worker for BojRest.JsWorkerPool.
// Reads newline-delimited JSON requests from stdin, writes responses to stdout.
//
// Request:  {"id":"...","mod":"/path/to/mod.js","tool":"toolName","args":{...},"env":{...}}
// Response: {"id":"...","status":200,"data":{...}}
//
// Requests are processed sequentially (one at a time via await).  The "env"
// field, when present, injects per-invocation credential vars into Deno.env
// before calling handleTool and cleans them up afterward — safe because there
// is no request concurrency in a single worker.
//
// Module-level caching: once a mod.js is imported, its handleTool function is
// cached for the lifetime of the worker.  This eliminates the re-import cost
// on every call after the first (the main point of the pool).

const decoder = new TextDecoder();
const encoder = new TextEncoder();
/** @type {Map<string, Function>} */
const modCache = new Map();

let buffer = "";

/**
 * @param {{ id: string, mod: string, tool: string, args?: object, env?: Record<string,string> }} req
 */
async function processRequest(req) {
  const { id, mod, tool, args = {}, env = {} } = req;

  const envKeys = Object.keys(env);
  for (const [k, v] of Object.entries(env)) Deno.env.set(k, v);

  try {
    let handleTool = modCache.get(mod);
    if (!handleTool) {
      const modUrl = mod.startsWith("/") ? `file://${mod}` : mod;
      const imported = await import(modUrl);
      handleTool = imported.handleTool;
      modCache.set(mod, handleTool);
    }

    const result = await handleTool(tool, args);
    const out = JSON.stringify({ id, status: result?.status ?? 200, data: result?.data ?? result });
    await Deno.stdout.write(encoder.encode(out + "\n"));
  } catch (err) {
    const out = JSON.stringify({ id, status: 500, data: { error: String(err) } });
    await Deno.stdout.write(encoder.encode(out + "\n"));
  } finally {
    for (const k of envKeys) Deno.env.delete(k);
  }
}

for await (const chunk of Deno.stdin.readable) {
  buffer += decoder.decode(chunk);
  let nl;
  while ((nl = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    let req;
    try {
      req = JSON.parse(line);
    } catch {
      // malformed — skip
      continue;
    }
    await processRequest(req);
  }
}
