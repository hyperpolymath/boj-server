// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// panic-attack-mcp/mod.js -- panic-attack-mcp gateway. Delegates to the `panic-attack` CLI binary.

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "panic_attack_scan": {
      const { path, verbose, format } = args ?? {};
      if (!path) return { status: 400, data: { error: "path is required" } };
      const cmd = new Deno.Command("panic-attack", { args: ["scan", String(path)], stdout: "piped", stderr: "piped" });
      const out = await cmd.output();
      if (!out.success) return { status: 500, data: { success: false, error: new TextDecoder().decode(out.stderr) } };
      const stdout = new TextDecoder().decode(out.stdout);
      try { return { status: 200, data: JSON.parse(stdout) }; } catch { return { status: 200, data: { success: true, output: stdout } }; }
    }

    case "panic_attack_get_findings": {
      const { scan_id } = args ?? {};
      if (!scan_id) return { status: 400, data: { error: "scan_id is required" } };
      const cmd = new Deno.Command("panic-attack", { args: ["get-findings", String(scan_id)], stdout: "piped", stderr: "piped" });
      const out = await cmd.output();
      if (!out.success) return { status: 500, data: { success: false, error: new TextDecoder().decode(out.stderr) } };
      const stdout = new TextDecoder().decode(out.stdout);
      try { return { status: 200, data: JSON.parse(stdout) }; } catch { return { status: 200, data: { success: true, output: stdout } }; }
    }

    case "panic_attack_get_severity": {
      const { scan_id } = args ?? {};
      if (!scan_id) return { status: 400, data: { error: "scan_id is required" } };
      const cmd = new Deno.Command("panic-attack", { args: ["get-severity", String(scan_id)], stdout: "piped", stderr: "piped" });
      const out = await cmd.output();
      if (!out.success) return { status: 500, data: { success: false, error: new TextDecoder().decode(out.stderr) } };
      const stdout = new TextDecoder().decode(out.stdout);
      try { return { status: 200, data: JSON.parse(stdout) }; } catch { return { status: 200, data: { success: true, output: stdout } }; }
    }
    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
