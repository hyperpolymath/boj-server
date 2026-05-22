// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// typed-wasm-mcp/mod.js — MCP gateway. Delegates to the `affinescript` CLI,
// which since 2026-05-03 carries the full typed-wasm Level 7/10 verifier
// (intra-module ownership) and the Level 10 cross-module boundary verifier.
//
// Tools:
//   typed_wasm_validate_module  → affinescript verify FILE.affine
//   typed_wasm_check_types      → affinescript check FILE.affine
//   typed_wasm_compile_module   → affinescript compile FILE.affine -o OUT.wasm
//
// All three accept .affine source paths. The verifier runs over the freshly
// emitted Wasm so there is no separate .wasm-input path: shipping unchecked
// .wasm and asking us to validate it would defeat the typed-wasm contract.
//
// Pass an explicit `output_path` to typed_wasm_compile_module; otherwise the
// .wasm is written next to the source.

const AFFINESCRIPT_BIN = Deno.env.get("AFFINESCRIPT_BIN") ?? "affinescript";

function dirOf(path) {
  const i = path.lastIndexOf("/");
  return i > 0 ? path.slice(0, i) : ".";
}

// `cwd` is set to the source's directory because affinescript's Module_loader
// resolves `use Foo.Bar` against the current working directory, not the source
// file's location.
async function runAffinescript(args, cwd) {
  try {
    const cmd = new Deno.Command(AFFINESCRIPT_BIN, {
      args,
      cwd,
      stdout: "piped",
      stderr: "piped",
    });
    const out = await cmd.output();
    const stdout = new TextDecoder().decode(out.stdout);
    const stderr = new TextDecoder().decode(out.stderr);
    return { code: out.code, stdout, stderr };
  } catch (e) {
    return { code: -1, stdout: "", stderr: `failed to spawn ${AFFINESCRIPT_BIN}: ${e.message}` };
  }
}

function requireString(args, key) {
  const v = args?.[key];
  if (typeof v !== "string" || v.length === 0) {
    return { error: `${key} (string) is required` };
  }
  return { value: v };
}

function deriveWasmPath(srcPath) {
  return srcPath.endsWith(".affine")
    ? srcPath.slice(0, -".affine".length) + ".wasm"
    : srcPath + ".wasm";
}

export async function handleTool(toolName, args) {
  switch (toolName) {
    case "typed_wasm_validate_module": {
      // Compiles + runs the intra-module Level 7/10 verifier (Tw_verify).
      // "Validation" = the emitted Wasm satisfies the typed-wasm ownership
      // contract declared in the source.
      const r = requireString(args, "module_path");
      if (r.error) return { status: 400, data: { error: r.error } };
      const out = await runAffinescript(["verify", r.value], dirOf(r.value));
      const valid = out.code === 0;
      return {
        status: valid ? 200 : 200,
        data: {
          valid,
          report: out.stdout.trim(),
          diagnostics: out.stderr.trim() || undefined,
        },
      };
    }

    case "typed_wasm_check_types": {
      // Runs only the type checker (no Wasm emission).
      const r = requireString(args, "module_path");
      if (r.error) return { status: 400, data: { error: r.error } };
      const out = await runAffinescript(["check", r.value], dirOf(r.value));
      const ok = out.code === 0;
      return {
        status: 200,
        data: {
          ok,
          report: out.stdout.trim(),
          errors: ok ? [] : (out.stderr.trim() ? [out.stderr.trim()] : []),
        },
      };
    }

    case "typed_wasm_compile_module": {
      // Compiles .affine → .wasm. The emitted module carries the
      // [affinescript.ownership] custom section consumed by typed-wasm
      // intra- and cross-module verifiers.
      const r = requireString(args, "module_path");
      if (r.error) return { status: 400, data: { error: r.error } };
      const outputPath = (typeof args?.output_path === "string" && args.output_path)
        ? args.output_path
        : deriveWasmPath(r.value);
      const out = await runAffinescript(["compile", r.value, "-o", outputPath], dirOf(r.value));
      const success = out.code === 0;
      return {
        status: success ? 200 : 200,
        data: {
          success,
          output_path: success ? outputPath : undefined,
          report: out.stdout.trim(),
          diagnostics: out.stderr.trim() || undefined,
        },
      };
    }

    case "typed_wasm_verify_boundary": {
      // Cross-module Level 10 boundary check. Compiles both files, then
      // verifies that the caller's local funcs respect the ownership
      // contract declared by the callee's Wasm exports.
      const callee = requireString(args, "callee_path");
      if (callee.error) return { status: 400, data: { error: callee.error } };
      const caller = requireString(args, "caller_path");
      if (caller.error) return { status: 400, data: { error: caller.error } };
      // Verify-boundary needs to find both files' imports — run from the
      // caller's directory (most likely the place where Callee lives too).
      const out = await runAffinescript(
        ["verify-boundary", callee.value, caller.value],
        dirOf(caller.value),
      );
      const clean = out.code === 0;
      return {
        status: 200,
        data: {
          clean,
          report: out.stdout.trim(),
          diagnostics: out.stderr.trim() || undefined,
        },
      };
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
