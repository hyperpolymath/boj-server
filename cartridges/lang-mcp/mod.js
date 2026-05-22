// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// lang-mcp/mod.js -- Multi-language session manager cartridge.
//
// Supports: Eclexia, AffineScript, BetLang, Ephapax, MyLang, WokeLang,
//           Anvomidav, Phronesis, Error-lang, Julia-the-Viper, Me-dialect,
//           Oblibeny (12 languages + custom).
//
// Unlike lsp-mcp/dap-mcp/bsp-mcp, this cartridge does NOT maintain a persistent
// server subprocess.  Instead it delegates each operation to the language's CLI
// tool via a short-lived subprocess call.  Session state is maintained in-process
// (language choice, dialect mode, open file state).
//
// Auth: None required — local CLI tools.
//
// Usage: import { handleTool } from "./mod.js";

// ---------------------------------------------------------------------------
// Language registry
// ---------------------------------------------------------------------------

// Each entry: { binary, checkArgs, evalArgs, compileArgs, hoverArgs, completeArgs }
// Arg templates may include "%file%" (tmp file path), "%line%", "%col%", "%target%"
const LANGUAGE_COMMANDS = {
  eclexia:        { binary: "eclexia",        checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  affinescript:   { binary: "affinescript",   checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "--target", "%target%", "--json", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  betlang:        { binary: "betlang",         checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  ephapax:        { binary: "ephapax",         checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  mylang:         { binary: "mylang",          checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  wokelang:       { binary: "wokelang",        checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  anvomidav:      { binary: "anvomidav",       checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  phronesis:      { binary: "phronesis",       checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  error_lang:     { binary: "error-lang",      checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  julia_the_viper:{ binary: "julia-the-viper", checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  me_dialect:     { binary: "me-dialect",      checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
  oblibeny:       { binary: "oblibeny",        checkArgs: ["check", "--json", "%file%"], evalArgs: ["eval", "%file%"], compileArgs: ["compile", "%file%"], hoverArgs: ["hover", "%file%", "%line%", "%col%"], completeArgs: ["complete", "%file%", "%line%", "%col%"] },
};

// Default compilation targets per language
const DEFAULT_TARGETS = {
  affinescript: "wasm",
  eclexia: "native",
  ephapax: "native",
};

// File extensions per language
const EXTENSIONS = {
  eclexia: "ecl", affinescript: "as", betlang: "bet", ephapax: "eph",
  mylang: "my", wokelang: "woke", anvomidav: "anv", phronesis: "phr",
  error_lang: "err", julia_the_viper: "jtv", me_dialect: "me", oblibeny: "obl",
};

// ---------------------------------------------------------------------------
// Session registry
// ---------------------------------------------------------------------------

/** @type {Map<string, {language: string, dialect_mode: string, name: string, state: string}>} */
const SESSIONS = new Map();

function newSessionId() {
  return `lang_${crypto.randomUUID().replace(/-/g, "").slice(0, 12)}`;
}

function getSession(session_id) {
  const s = SESSIONS.get(session_id);
  if (!s) throw Object.assign(new Error(`Unknown lang session: ${session_id}`), { status: 404 });
  return s;
}

// ---------------------------------------------------------------------------
// Subprocess helper
// ---------------------------------------------------------------------------

async function runCLI(binary, cliArgs, input = null) {
  try {
    const proc = new Deno.Command(binary, {
      args: cliArgs,
      stdin: input != null ? "piped" : "null",
      stdout: "piped",
      stderr: "piped",
    }).spawn();

    if (input != null) {
      const writer = proc.stdin.getWriter();
      await writer.write(new TextEncoder().encode(input));
      await writer.close();
    }

    const { code, stdout, stderr } = await proc.output();
    const dec = new TextDecoder();
    return { exitCode: code, stdout: dec.decode(stdout), stderr: dec.decode(stderr) };
  } catch (e) {
    return { exitCode: -1, stdout: "", stderr: `Failed to invoke ${binary}: ${e.message}` };
  }
}

/** Write source to a tmp file, run the CLI, then remove the file. */
async function withTmpFile(language, source, fn) {
  const ext = EXTENSIONS[language] ?? "txt";
  const path = `/tmp/boj_lang_${crypto.randomUUID().replace(/-/g, "").slice(0, 8)}.${ext}`;
  try {
    await Deno.writeTextFile(path, source);
    return await fn(path);
  } finally {
    try { await Deno.remove(path); } catch { /* ignore */ }
  }
}

/** Substitute template variables in an arg array. */
function renderArgs(template, vars) {
  return template.map(a => {
    let r = a;
    for (const [k, v] of Object.entries(vars)) r = r.replace(k, v);
    return r;
  });
}

/** Try to probe whether a binary is installed (exits cleanly or with usage error). */
async function isInstalled(binary) {
  try {
    const r = await new Deno.Command(binary, { args: ["--version"], stdout: "null", stderr: "null" }).output();
    return r.code === 0;
  } catch { return false; }
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // -- lang_list -----------------------------------------------------------
    case "lang_list": {
      const { check_installed = true } = args ?? {};
      const languages = await Promise.all(
        Object.entries(LANGUAGE_COMMANDS).map(async ([id, cfg]) => {
          const installed = check_installed ? await isInstalled(cfg.binary) : null;
          return { id, binary: cfg.binary, installed, operations: ["check", "eval", "compile", "hover", "complete"] };
        })
      );
      return { status: 200, data: { languages, count: languages.length } };
    }

    // -- lang_session_create -------------------------------------------------
    case "lang_session_create": {
      const { language, dialect_mode = "pure", name } = args;
      if (!LANGUAGE_COMMANDS[language]) {
        return { status: 400, data: { error: `Unknown language: ${language}. Known: ${Object.keys(LANGUAGE_COMMANDS).join(", ")}` } };
      }
      const session_id = newSessionId();
      SESSIONS.set(session_id, { language, dialect_mode, name: name ?? `${language}-session`, state: "idle" });
      return { status: 200, data: { session_id, language, dialect_mode, name: name ?? `${language}-session` } };
    }

    // -- lang_session_status -------------------------------------------------
    case "lang_session_status": {
      const { session_id } = args;
      const s = getSession(session_id);
      return { status: 200, data: { session_id, language: s.language, dialect_mode: s.dialect_mode, name: s.name, state: s.state } };
    }

    // -- lang_check ----------------------------------------------------------
    case "lang_check": {
      const { session_id, source, filename } = args;
      const s = getSession(session_id);
      const cfg = LANGUAGE_COMMANDS[s.language];
      s.state = "compiling";
      try {
        const result = await withTmpFile(s.language, source, async (path) => {
          const cliArgs = renderArgs(cfg.checkArgs, { "%file%": path });
          return runCLI(cfg.binary, cliArgs);
        });
        let diagnostics;
        try { diagnostics = JSON.parse(result.stderr || result.stdout); }
        catch { diagnostics = { success: result.exitCode === 0, raw: result.stderr || result.stdout }; }
        s.state = result.exitCode === 0 ? "checked" : "error";
        return { status: result.exitCode === 0 ? 200 : 422, data: diagnostics };
      } finally {
        if (s.state === "compiling") s.state = "error";
      }
    }

    // -- lang_eval -----------------------------------------------------------
    case "lang_eval": {
      const { session_id, source } = args;
      const s = getSession(session_id);
      const cfg = LANGUAGE_COMMANDS[s.language];
      s.state = "evaluating";
      try {
        const result = await withTmpFile(s.language, source, async (path) => {
          const cliArgs = renderArgs(cfg.evalArgs, { "%file%": path });
          return runCLI(cfg.binary, cliArgs);
        });
        s.state = result.exitCode === 0 ? "idle" : "error";
        return {
          status: result.exitCode === 0 ? 200 : 422,
          data: { output: result.stdout, stderr: result.stderr, exit_code: result.exitCode },
        };
      } finally {
        if (s.state === "evaluating") s.state = "error";
      }
    }

    // -- lang_compile --------------------------------------------------------
    case "lang_compile": {
      const { session_id, source, target } = args;
      const s = getSession(session_id);
      const cfg = LANGUAGE_COMMANDS[s.language];
      const compilationTarget = target ?? DEFAULT_TARGETS[s.language] ?? "native";
      s.state = "compiling";
      try {
        const result = await withTmpFile(s.language, source, async (path) => {
          const cliArgs = renderArgs(cfg.compileArgs, { "%file%": path, "%target%": compilationTarget });
          return runCLI(cfg.binary, cliArgs);
        });
        let report;
        try { report = JSON.parse(result.stderr || result.stdout); }
        catch { report = { success: result.exitCode === 0, raw: result.stderr || result.stdout }; }
        s.state = result.exitCode === 0 ? "idle" : "error";
        return { status: result.exitCode === 0 ? 200 : 422, data: { target: compilationTarget, ...report } };
      } finally {
        if (s.state === "compiling") s.state = "error";
      }
    }

    // -- lang_hover ----------------------------------------------------------
    case "lang_hover": {
      const { session_id, source, line, col } = args;
      const s = getSession(session_id);
      const cfg = LANGUAGE_COMMANDS[s.language];
      const result = await withTmpFile(s.language, source, async (path) => {
        const cliArgs = renderArgs(cfg.hoverArgs, { "%file%": path, "%line%": String(line), "%col%": String(col) });
        return runCLI(cfg.binary, cliArgs);
      });
      let hover;
      try { hover = JSON.parse(result.stdout); }
      catch { hover = { text: result.stdout.trim() || null }; }
      return { status: result.exitCode === 0 ? 200 : 422, data: hover };
    }

    // -- lang_complete -------------------------------------------------------
    case "lang_complete": {
      const { session_id, source, line, col } = args;
      const s = getSession(session_id);
      const cfg = LANGUAGE_COMMANDS[s.language];
      const result = await withTmpFile(s.language, source, async (path) => {
        const cliArgs = renderArgs(cfg.completeArgs, { "%file%": path, "%line%": String(line), "%col%": String(col) });
        return runCLI(cfg.binary, cliArgs);
      });
      let items;
      try { items = JSON.parse(result.stdout); }
      catch { items = []; }
      if (!Array.isArray(items)) items = items.items ?? [];
      return { status: result.exitCode === 0 ? 200 : 422, data: { items, count: items.length } };
    }

    // -- lang_session_close --------------------------------------------------
    case "lang_session_close": {
      const { session_id } = args;
      if (!SESSIONS.has(session_id)) return { status: 404, data: { error: `Unknown session: ${session_id}` } };
      SESSIONS.delete(session_id);
      return { status: 200, data: { closed: session_id } };
    }

    default:
      return { status: 404, data: { error: `Unknown tool: ${toolName}` } };
  }
}
