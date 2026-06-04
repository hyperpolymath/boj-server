// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// js_runner.js — thin Deno harness that imports a cartridge mod.js and calls
// handleTool(toolName, args), writing { status, data } JSON to stdout.
//
// Invoked by BojRest.JsInvoker as:
//   deno run --allow-net --allow-env --allow-read js_runner.js <abs_mod_path> <tool_name> <args_json>
//
// Exit codes:
//   0  — handleTool returned (success or application-level error in data)
//   1  — runner itself failed (bad args, import error, unhandled throw)

const [modPath, toolName, argsJson] = Deno.args;

if (!modPath || !toolName) {
  console.error(JSON.stringify({
    status: 400,
    data: { error: "js_runner requires: <mod_path> <tool_name> [args_json]" },
  }));
  Deno.exit(1);
}

let args = {};
if (argsJson) {
  try {
    args = JSON.parse(argsJson);
  } catch (_) {
    console.error(JSON.stringify({
      status: 400,
      data: { error: `args_json is not valid JSON: ${argsJson}` },
    }));
    Deno.exit(1);
  }
}

// Dynamic import: convert absolute path to file URL so Deno resolves it
// correctly on all platforms without needing --allow-import-host.
const modUrl = modPath.startsWith("/") ? `file://${modPath}` : modPath;

try {
  const mod = await import(modUrl);

  if (typeof mod.handleTool !== "function") {
    console.error(JSON.stringify({
      status: 500,
      data: { error: `${modPath} does not export handleTool` },
    }));
    Deno.exit(1);
  }

  const result = await mod.handleTool(toolName, args);

  // Ensure result always has the expected shape { status, data }
  if (result && typeof result.status === "number" && "data" in result) {
    console.log(JSON.stringify(result));
  } else {
    // handleTool returned something unusual — wrap it
    console.log(JSON.stringify({ status: 200, data: result }));
  }
} catch (e) {
  console.error(JSON.stringify({
    status: 500,
    data: { error: `handleTool threw: ${e.message}`, stack: e.stack },
  }));
  Deno.exit(1);
}
