// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// typed-wasm-mcp/mod.js -- typed-wasm-mcp gateway. Delegates to the `typed-wasm` CLI binary.

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "typed_wasm_validate_module": {
      const { module_path } = args ?? {};
      if (!module_path) return { status: 400, data: { error: "module_path is required" } };
      const cmd = new Deno.Command("typed-wasm", { args: ["validate-module", String(module_path)], stdout: "piped", stderr: "piped" });
      const out = await cmd.output();
      if (!out.success) return { status: 500, data: { success: false, error: new TextDecoder().decode(out.stderr) } };
      const stdout = new TextDecoder().decode(out.stdout);
      try { return { status: 200, data: JSON.parse(stdout) }; } catch { return { status: 200, data: { success: true, output: stdout } }; }
    }

    case "typed_wasm_check_types": {
      const { module_path } = args ?? {};
      if (!module_path) return { status: 400, data: { error: "module_path is required" } };
      const cmd = new Deno.Command("typed-wasm", { args: ["check-types", String(module_path)], stdout: "piped", stderr: "piped" });
      const out = await cmd.output();
      if (!out.success) return { status: 500, data: { success: false, error: new TextDecoder().decode(out.stderr) } };
      const stdout = new TextDecoder().decode(out.stdout);
      try { return { status: 200, data: JSON.parse(stdout) }; } catch { return { status: 200, data: { success: true, output: stdout } }; }
    }

    case "typed_wasm_compile_module": {
      const { module_path, target } = args ?? {};
      if (!module_path) return { status: 400, data: { error: "module_path is required" } };
      const cmd = new Deno.Command("typed-wasm", { args: ["compile-module", String(module_path)], stdout: "piped", stderr: "piped" });
      const out = await cmd.output();
      if (!out.success) return { status: 500, data: { success: false, error: new TextDecoder().decode(out.stderr) } };
      const stdout = new TextDecoder().decode(out.stdout);
      try { return { status: 200, data: JSON.parse(stdout) }; } catch { return { status: 200, data: { success: true, output: stdout } }; }
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
