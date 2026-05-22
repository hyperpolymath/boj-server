// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// affinescript-mcp/mod.js -- AffineScript language cartridge implementation.
//
// Provides MCP tool handlers for AffineScript compiler operations:
//   - Type checking    (via `affinescript check --json`)
//   - Parsing          (via `affinescript parse`)
//   - Formatting       (built-in indentation formatter)
//   - Linting          (via `affinescript lint --json`)
//   - Compilation      (via `affinescript compile --json`)
//   - Hover            (via `affinescript hover FILE LINE COL`)
//   - Goto-definition  (via `affinescript goto-def FILE LINE COL`)
//   - Completion       (via `affinescript complete FILE LINE COL`)
//   - Error explanation  (static lookup)
//   - Standard library browsing (static reference)
//   - Syntax reference   (static lookup)
//   - Snippet evaluation (via `affinescript eval`)
//
// Auth: None required — local compiler invocation.
// Compiler: OCaml-based, installed at `affinescript` on PATH.
//
// Usage: import { handleTool } from "./mod.js";

// ---------------------------------------------------------------------------
// Subprocess helper — invokes the affinescript compiler CLI.
// ---------------------------------------------------------------------------

async function runCompiler(args, input) {
  try {
    const cmd = new Deno.Command("affinescript", {
      args,
      stdin: input ? "piped" : "null",
      stdout: "piped",
      stderr: "piped",
    });

    const proc = cmd.spawn();

    if (input) {
      const writer = proc.stdin.getWriter();
      await writer.write(new TextEncoder().encode(input));
      await writer.close();
    }

    const { code, stdout, stderr } = await proc.output();
    const dec = new TextDecoder();

    return {
      exitCode: code,
      stdout: dec.decode(stdout),
      stderr: dec.decode(stderr),
    };
  } catch (e) {
    return {
      exitCode: -1,
      stdout: "",
      stderr: `Failed to invoke affinescript: ${e.message}. Is the compiler installed?`,
    };
  }
}

// ---------------------------------------------------------------------------
// Error code reference — maps codes to explanations.
// Categories: E0 (parse), E1 (type), E2 (borrow/affine), E3 (effect),
// E4 (quantity), E5 (name), E6 (refinement), W (warning), L (lint).
// ---------------------------------------------------------------------------

const ERROR_CODES = {
  // Parse errors
  "E0001": { category: "Parse", title: "Unexpected token", description: "The parser encountered a token it did not expect at this position.", fix: "Check for missing semicolons, unmatched braces, or typos in keywords." },
  "E0002": { category: "Parse", title: "Unterminated string literal", description: "A string literal was opened but never closed.", fix: "Add the closing quote character." },
  "E0003": { category: "Parse", title: "Invalid numeric literal", description: "A number literal has invalid format.", fix: "Check for stray decimal points, invalid suffixes, or mixed radix digits." },

  // Type errors
  "E1001": { category: "Type", title: "Type mismatch", description: "Expected one type but found another.", fix: "Check that the expression's type matches the expected type in context." },
  "E1002": { category: "Type", title: "Undefined type", description: "Referenced a type that has not been defined.", fix: "Declare the type or import the module that defines it." },
  "E1003": { category: "Type", title: "Infinite type", description: "Type inference produced a recursive type without an explicit recursive wrapper.", fix: "Add an explicit type annotation or use a named recursive type." },

  // Borrow/affine errors
  "E2001": { category: "Borrow", title: "Use after move", description: "A value with affine or linear type was used after being moved.", fix: "Clone the value before moving, or restructure to avoid the second use." },
  "E2002": { category: "Borrow", title: "Double move", description: "A linear/affine value was moved more than once.", fix: "Ensure each value flows through exactly one consumer." },
  "E2003": { category: "Borrow", title: "Linear value not consumed", description: "A linear value went out of scope without being consumed.", fix: "Use the value or explicitly drop it with a handler." },
  "E2004": { category: "Borrow", title: "Invalid borrow", description: "Attempted to borrow a value that is not available for borrowing.", fix: "Check that the value has not been moved and the borrow lifetime is valid." },

  // Effect errors
  "E3001": { category: "Effect", title: "Unhandled effect", description: "A computation performs an effect that is not handled in the current scope.", fix: "Wrap the computation in an effect handler or propagate the effect in the type signature." },
  "E3002": { category: "Effect", title: "Effect mismatch", description: "Handler does not match the expected effect signature.", fix: "Ensure handler operations match the effect declaration." },

  // Quantity errors
  "E4001": { category: "Quantity", title: "Quantity violation", description: "A value was used in a way that violates its quantity annotation (linear, affine, unrestricted).", fix: "Check the quantity qualifier and adjust usage accordingly." },

  // Name resolution errors
  "E5001": { category: "Name", title: "Undefined variable", description: "Referenced a variable that has not been defined in scope.", fix: "Define the variable or check for typos." },
  "E5002": { category: "Name", title: "Duplicate definition", description: "A name was defined more than once in the same scope.", fix: "Rename one of the definitions or use a different scope." },

  // Refinement type errors
  "E6001": { category: "Refinement", title: "Refinement type violation", description: "A value does not satisfy the refinement predicate on its type.", fix: "Ensure the value meets the declared constraints." },

  // Warnings
  "W0001": { category: "Warning", title: "Unused variable", description: "A variable was declared but never used.", fix: "Remove the variable or prefix with underscore (_) to mark as intentionally unused." },
  "W0002": { category: "Warning", title: "Unreachable code", description: "Code after this point can never be executed.", fix: "Remove the unreachable code or fix the control flow." },
  "W0003": { category: "Warning", title: "Unnecessary qualification", description: "An explicitly unrestricted variable could be inferred automatically.", fix: "Remove the explicit qualifier — it will be inferred." },

  // Lint
  "L0001": { category: "Lint", title: "Non-standard naming", description: "Name does not follow AffineScript naming conventions (snake_case for values, PascalCase for types).", fix: "Rename to follow conventions." },
};

// ---------------------------------------------------------------------------
// Standard library reference
// ---------------------------------------------------------------------------

const STDLIB = {
  types: [
    { name: "Int", description: "Arbitrary-precision integer", category: "types" },
    { name: "Float", description: "64-bit IEEE 754 floating-point", category: "types" },
    { name: "Bool", description: "Boolean (true/false)", category: "types" },
    { name: "String", description: "UTF-8 string (immutable)", category: "types" },
    { name: "Unit", description: "Unit type (single value ())", category: "types" },
    { name: "List", description: "Immutable linked list", category: "collections" },
    { name: "Array", description: "Mutable contiguous array", category: "collections" },
    { name: "Map", description: "Immutable hash map", category: "collections" },
    { name: "Set", description: "Immutable hash set", category: "collections" },
    { name: "Option", description: "Optional value (Some(x) | None)", category: "types" },
    { name: "Result", description: "Error handling (Ok(x) | Err(e))", category: "types" },
    { name: "Channel", description: "Typed channel for effect-based concurrency", category: "effects" },
  ],
  functions: [
    { name: "print", signature: "fn print(x: String) -> Unit / IO", category: "io" },
    { name: "println", signature: "fn println(x: String) -> Unit / IO", category: "io" },
    { name: "read_line", signature: "fn read_line() -> String / IO", category: "io" },
    { name: "read_file", signature: "fn read_file(path: String) -> Result[String, IOError] / IO", category: "io" },
    { name: "map", signature: "fn map[A, B](xs: List[A], f: fn(A) -> B) -> List[B]", category: "collections" },
    { name: "filter", signature: "fn filter[A](xs: List[A], f: fn(A) -> Bool) -> List[A]", category: "collections" },
    { name: "fold", signature: "fn fold[A, B](xs: List[A], init: B, f: fn(B, A) -> B) -> B", category: "collections" },
    { name: "length", signature: "fn length[A](xs: List[A]) -> Int", category: "collections" },
    { name: "to_string", signature: "fn to_string[A: Show](x: A) -> String", category: "types" },
    { name: "clone", signature: "fn clone[A: Clone](x: &A) -> A", category: "types" },
  ],
  effects: [
    { name: "IO", description: "Input/output side effects", category: "effects" },
    { name: "State", description: "Mutable state effect: get, put, modify", category: "effects" },
    { name: "Exception", description: "Exception effect: raise, catch", category: "effects" },
    { name: "Async", description: "Asynchronous computation effect: await, spawn", category: "effects" },
    { name: "NonDet", description: "Non-deterministic choice effect", category: "effects" },
  ],
  traits: [
    { name: "Show", description: "Convert to string representation", category: "traits" },
    { name: "Eq", description: "Structural equality comparison", category: "traits" },
    { name: "Ord", description: "Total ordering", category: "traits" },
    { name: "Clone", description: "Deep copy (unrestricted types only)", category: "traits" },
    { name: "Hash", description: "Hash value computation", category: "traits" },
    { name: "Default", description: "Default value construction", category: "traits" },
  ],
};

// ---------------------------------------------------------------------------
// Syntax reference
// ---------------------------------------------------------------------------

const SYNTAX_REF = {
  "fn": { title: "Function definition", syntax: "fn name(param: Type) -> ReturnType / Effects { body }", example: "fn add(x: Int, y: Int) -> Int {\n  x + y\n}", notes: "Functions are first-class values. Effect annotations after `/` are optional." },
  "let": { title: "Variable binding", syntax: "let name: Type = expr", example: "let x: Int = 42\nlet y = \"hello\"  // type inferred", notes: "Bindings are immutable by default. Type annotations are optional when inferable." },
  "type": { title: "Type alias", syntax: "type Name = ExistingType", example: "type Pair[A, B] = (A, B)\ntype Predicate[A] = fn(A) -> Bool", notes: "Creates a transparent alias — no new nominal type." },
  "struct": { title: "Structure type", syntax: "struct Name { field: Type, ... }", example: "struct Point {\n  x: Float,\n  y: Float,\n}", notes: "Product type with named fields. Supports pattern matching." },
  "enum": { title: "Enumeration type", syntax: "enum Name { Variant1(Type), Variant2, ... }", example: "enum Shape {\n  Circle(Float),\n  Rectangle(Float, Float),\n  Point,\n}", notes: "Sum type (tagged union). Each variant can carry data." },
  "effect": { title: "Effect declaration", syntax: "effect Name { op(Type) -> Type }", example: "effect State[S] {\n  get() -> S\n  put(S) -> Unit\n}", notes: "Algebraic effects declare operations that can be handled by effect handlers." },
  "handler": { title: "Effect handler", syntax: "handler name { op(args) -> resume(result) }", example: "handler state_handler[S](init: S) {\n  get() -> resume(current_state)\n  put(s) -> resume(())\n}", notes: "Handlers provide implementations for effect operations. `resume` is the continuation." },
  "match": { title: "Pattern matching", syntax: "match expr { pattern => body, ... }", example: "match opt {\n  Some(x) => x + 1,\n  None => 0,\n}", notes: "Exhaustive pattern matching. Compiler checks completeness." },
  "linear": { title: "Linear type qualifier", syntax: "linear Type", example: "let handle: linear FileHandle = open(\"data.txt\")\n// handle MUST be used exactly once", notes: "Linear values must be consumed exactly once. Prevents resource leaks." },
  "affine": { title: "Affine type qualifier", syntax: "affine Type", example: "let token: affine AuthToken = authenticate()\n// token can be used at most once", notes: "Affine values can be used zero or one times. Dropped values are safe." },
  "unrestricted": { title: "Unrestricted type qualifier", syntax: "unrestricted Type", example: "let x: unrestricted Int = 42\n// x can be used any number of times", notes: "Default qualifier for most types. No usage restrictions." },
  "borrow": { title: "Borrow expression", syntax: "borrow value", example: "fn peek(list: &List[Int]) -> Int {\n  // list is borrowed — not consumed\n  list.head()\n}", notes: "Creates a temporary reference without consuming the value." },
  "move": { title: "Move expression", syntax: "move value", example: "let a: linear Channel = create_channel()\nlet b = move a  // ownership transferred\n// a is no longer valid", notes: "Explicitly transfers ownership of a value." },
  "if": { title: "Conditional", syntax: "if condition { then } else { otherwise }", example: "if x > 0 {\n  \"positive\"\n} else {\n  \"non-positive\"\n}", notes: "If-else is an expression — both branches must have compatible types." },
  "for": { title: "For loop", syntax: "for var in iterable { body }", example: "for item in list {\n  println(to_string(item))\n}", notes: "Iterates over any type implementing the Iterator trait." },
  "return": { title: "Return statement", syntax: "return expr", example: "fn early_exit(x: Int) -> String {\n  if x < 0 { return \"negative\" }\n  \"non-negative\"\n}", notes: "Explicit early return. The last expression in a block is the implicit return." },
};

// ---------------------------------------------------------------------------
// Tool handler dispatch
// ---------------------------------------------------------------------------

export async function handleTool(toolName, args) {
  switch (toolName) {

    // --- Type checking ---

    case "affinescript_check": {
      if (!args.source) return { error: "Missing required field: source" };

      const tmpFile = `/tmp/boj_afs_${crypto.randomUUID()}.as`;

      try {
        await Deno.writeTextFile(tmpFile, args.source);
        // --json emits a structured JSON object on stderr
        const result = await runCompiler(["check", "--json", tmpFile], null);

        let report;
        try {
          report = JSON.parse(result.stderr.trim());
        } catch {
          // Fallback: compiler stderr was not JSON (unexpected)
          report = { success: result.exitCode === 0, diagnostics: [], raw: result.stderr };
        }

        return {
          status: result.exitCode === 0 ? 200 : 422,
          data: report,
        };
      } finally {
        try { await Deno.remove(tmpFile); } catch { /* ignore */ }
      }
    }

    // --- Parsing ---

    case "affinescript_parse": {
      if (!args.source) return { error: "Missing required field: source" };

      const tmpFile = `/tmp/boj_afs_${crypto.randomUUID()}.as`;

      try {
        await Deno.writeTextFile(tmpFile, args.source);
        const result = await runCompiler(["parse", tmpFile], null);

        return {
          status: result.exitCode === 0 ? 200 : 422,
          data: {
            success: result.exitCode === 0,
            ast: result.stdout || undefined,
            errors: result.stderr || undefined,
          },
        };
      } finally {
        try { await Deno.remove(tmpFile); } catch { /* ignore */ }
      }
    }

    // --- Formatting ---

    case "affinescript_format": {
      if (!args.source) return { error: "Missing required field: source" };

      const tabSize = args.tab_size || 2;
      const useTabs = args.use_tabs || false;
      const indent = useTabs ? "\t" : " ".repeat(tabSize);

      const lines = args.source.split("\n");
      const formatted = [];
      let indentLevel = 0;

      for (const line of lines) {
        const trimmed = line.trim();

        if (trimmed.startsWith("}") || trimmed.startsWith("]") || trimmed.startsWith(")")) {
          indentLevel = Math.max(0, indentLevel - 1);
        }

        formatted.push(trimmed.length > 0 ? indent.repeat(indentLevel) + trimmed : "");

        if (trimmed.endsWith("{") || trimmed.endsWith("[") || trimmed.endsWith("(")) {
          indentLevel += 1;
        }
      }

      return {
        status: 200,
        data: {
          formatted: formatted.join("\n"),
          changed: formatted.join("\n") !== args.source,
        },
      };
    }

    // --- Error explanation ---

    case "affinescript_explain_error": {
      if (!args.code) return { error: "Missing required field: code" };

      const code = args.code.toUpperCase();
      const entry = ERROR_CODES[code];

      if (!entry) {
        return {
          status: 404,
          data: {
            code,
            error: `Unknown error code: ${code}. Valid prefixes: E0 (parse), E1 (type), E2 (borrow), E3 (effect), E4 (quantity), E5 (name), E6 (refinement), W (warning), L (lint).`,
          },
        };
      }

      return {
        status: 200,
        data: { code, ...entry },
      };
    }

    // --- Stdlib browsing ---

    case "affinescript_stdlib": {
      if (!args.query) return { error: "Missing required field: query" };

      const query = args.query.toLowerCase();
      const category = args.category?.toLowerCase();
      const results = [];

      for (const [section, items] of Object.entries(STDLIB)) {
        if (category && section !== category) continue;

        for (const item of items) {
          const nameMatch = item.name.toLowerCase().includes(query);
          const descMatch = (item.description || "").toLowerCase().includes(query);
          const catMatch = (item.category || "").toLowerCase().includes(query);

          if (nameMatch || descMatch || catMatch) {
            results.push({ section, ...item });
          }
        }
      }

      return {
        status: 200,
        data: { query: args.query, results, count: results.length },
      };
    }

    // --- Syntax reference ---

    case "affinescript_syntax_ref": {
      if (!args.construct) return { error: "Missing required field: construct" };

      const key = args.construct.toLowerCase();
      const entry = SYNTAX_REF[key];

      if (!entry) {
        const available = Object.keys(SYNTAX_REF).join(", ");
        return {
          status: 404,
          data: {
            construct: args.construct,
            error: `Unknown construct: ${args.construct}. Available: ${available}`,
          },
        };
      }

      return {
        status: 200,
        data: { construct: args.construct, ...entry },
      };
    }

    // --- Snippet evaluation ---

    case "affinescript_snippet": {
      if (!args.source) return { error: "Missing required field: source" };

      const tmpFile = `/tmp/boj_afs_${crypto.randomUUID()}.as`;

      try {
        await Deno.writeTextFile(tmpFile, args.source);
        const result = await runCompiler(["eval", tmpFile], null);

        return {
          status: result.exitCode === 0 ? 200 : 422,
          data: {
            success: result.exitCode === 0,
            result: result.stdout?.trim() || undefined,
            errors: result.stderr || undefined,
          },
        };
      } finally {
        try { await Deno.remove(tmpFile); } catch { /* ignore */ }
      }
    }

    // --- Linting ---

    case "affinescript_lint": {
      if (!args.source) return { error: "Missing required field: source" };

      const tmpFile = `/tmp/boj_afs_${crypto.randomUUID()}.as`;

      try {
        await Deno.writeTextFile(tmpFile, args.source);
        const result = await runCompiler(["lint", "--json", tmpFile], null);

        let report;
        try {
          report = JSON.parse(result.stderr.trim());
        } catch {
          report = { success: result.exitCode === 0, diagnostics: [], raw: result.stderr };
        }

        return {
          status: result.exitCode === 0 ? 200 : 422,
          data: report,
        };
      } finally {
        try { await Deno.remove(tmpFile); } catch { /* ignore */ }
      }
    }

    // --- Compilation ---

    case "affinescript_compile": {
      if (!args.source) return { error: "Missing required field: source" };

      const target = args.target || "wasm";
      const tmpSrc = `/tmp/boj_afs_${crypto.randomUUID()}.as`;
      const ext = target === "julia" ? "jl" : "wasm";
      const tmpOut = `/tmp/boj_afs_out_${crypto.randomUUID()}.${ext}`;

      const compileArgs = ["compile", "--json"];
      if (target === "wasm-gc") compileArgs.push("--wasm-gc");
      compileArgs.push("-o", tmpOut, tmpSrc);

      try {
        await Deno.writeTextFile(tmpSrc, args.source);
        const result = await runCompiler(compileArgs, null);

        let report;
        try {
          report = JSON.parse(result.stderr.trim());
        } catch {
          report = { success: result.exitCode === 0, diagnostics: [], raw: result.stderr };
        }

        return {
          status: result.exitCode === 0 ? 200 : 422,
          data: { ...report, target },
        };
      } finally {
        try { await Deno.remove(tmpSrc); } catch { /* ignore */ }
        try { await Deno.remove(tmpOut); } catch { /* ignore */ }
      }
    }

    // --- Hover ---

    case "affinescript_hover": {
      if (!args.source) return { error: "Missing required field: source" };
      if (args.line == null) return { error: "Missing required field: line" };
      if (args.col == null) return { error: "Missing required field: col" };

      const tmpFile = `/tmp/boj_afs_${crypto.randomUUID()}.as`;

      try {
        await Deno.writeTextFile(tmpFile, args.source);
        // hover outputs JSON on stdout; line/col are 1-based
        const result = await runCompiler(
          ["hover", tmpFile, String(args.line), String(args.col)],
          null
        );

        let info;
        try {
          info = JSON.parse(result.stdout.trim());
        } catch {
          info = { found: false, raw: result.stdout };
        }

        return {
          status: 200,
          data: info,
        };
      } finally {
        try { await Deno.remove(tmpFile); } catch { /* ignore */ }
      }
    }

    // --- Goto-definition ---

    case "affinescript_goto_def": {
      if (!args.source) return { error: "Missing required field: source" };
      if (args.line == null) return { error: "Missing required field: line" };
      if (args.col == null) return { error: "Missing required field: col" };

      const tmpFile = `/tmp/boj_afs_${crypto.randomUUID()}.as`;

      try {
        await Deno.writeTextFile(tmpFile, args.source);
        // goto-def outputs JSON on stdout; line/col are 1-based
        const result = await runCompiler(
          ["goto-def", tmpFile, String(args.line), String(args.col)],
          null
        );

        let info;
        try {
          info = JSON.parse(result.stdout.trim());
        } catch {
          info = { found: false, raw: result.stdout };
        }

        return {
          status: 200,
          data: info,
        };
      } finally {
        try { await Deno.remove(tmpFile); } catch { /* ignore */ }
      }
    }

    // --- Completion ---

    case "affinescript_complete": {
      if (!args.source) return { error: "Missing required field: source" };
      if (args.line == null) return { error: "Missing required field: line" };
      if (args.col == null) return { error: "Missing required field: col" };

      const tmpFile = `/tmp/boj_afs_${crypto.randomUUID()}.as`;

      try {
        await Deno.writeTextFile(tmpFile, args.source);
        // complete outputs a JSON array on stdout; line/col are 1-based
        const result = await runCompiler(
          ["complete", tmpFile, String(args.line), String(args.col)],
          null
        );

        let items;
        try {
          items = JSON.parse(result.stdout.trim());
        } catch {
          items = [];
        }

        return {
          status: 200,
          data: { items, count: Array.isArray(items) ? items.length : 0 },
        };
      } finally {
        try { await Deno.remove(tmpFile); } catch { /* ignore */ }
      }
    }

    default:
      return { error: `Unknown affinescript-mcp tool: ${toolName}` };
  }
}

// ---------------------------------------------------------------------------
// Diagnostic parser — converts compiler stderr to structured diagnostics.
// Format: "file:line:col: severity [CODE]: message"
// ---------------------------------------------------------------------------

function parseDiagnostics(stderr, filename) {
  if (!stderr) return [];

  const diagnostics = [];
  const re = /(.+):(\d+):(\d+):\s*(error|warning|hint|info|note)\s*(?:\[([A-Z]\d+)\])?:\s*(.+)/g;
  let match;

  while ((match = re.exec(stderr)) !== null) {
    diagnostics.push({
      file: filename,
      line: parseInt(match[2], 10),
      column: parseInt(match[3], 10),
      severity: match[4],
      code: match[5] || null,
      message: match[6],
    });
  }

  return diagnostics;
}

// ---------------------------------------------------------------------------
// Cartridge metadata export
// ---------------------------------------------------------------------------

export const metadata = {
  name: "affinescript-mcp",
  version: "0.1.0",
  domain: "Languages",
  tier: "Ayo",
  protocols: ["MCP", "REST"],
  toolCount: 12,
};
