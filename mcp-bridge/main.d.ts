// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Type declaration for mcp-bridge/main.js — script entrypoint
//
// `main.js` is an executable stdio bridge, not a library. It is the
// command run by MCP clients via `npx -y @hyperpolymath/boj-server@latest`
// or `deno run -A mcp-bridge/main.js`. It reads JSON-RPC from stdin,
// writes responses to stdout, and exits when stdin closes.
//
// This file exists solely to satisfy JSR's slow-types check for the
// entrypoint declared in `jsr.json`'s `exports` field. The public
// surface is intentionally empty — clients interact with this module
// by running it as a process, not by importing it.
//
// Library APIs (intended for direct import) live under `lib/`:
//   - lib/tools.js      — buildToolList()
//   - lib/resources.js  — listResources(), readResource(uri)
//   - lib/prompts.js    — listPrompts(), getPrompt(name, args)
//   - lib/runtime.js    — env, stdout, stderr, isDeno
//   - lib/otel.js       — startSpan(), endSpan(), flush(), init(), isEnabled()
//   - lib/security.js   — sanitizeErrorMessage(), rateLimitAllow(), …
//   - lib/api-clients.js — fetchHealth(), fetchMenu(), invokeCartridge(), …
//   - lib/nickel-validator.js — validateEnvelope(), tryParseEnvelope()
//   - lib/logger.js     — info(), warn(), error(), setLevel()

export {};
