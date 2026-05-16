// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Nickel envelope validator — runtime check for coord_send / coord_send_gated
// envelope bodies (Task #17).
//
// Before the mcp-bridge forwards a coord_send(_gated) call to the Zig
// adapter, the incoming `message` payload is parsed (if JSON) and run
// through `contracts.validate` from coord-messages-contracts.ncl via
// a `nickel eval` subprocess. Invalid envelopes are rejected with a
// descriptive MCP error — they never reach the loopback adapter.
//
// Design notes:
//
//   * The Nickel CLI is invoked per-call. No long-running Nickel process
//     today; the contract file is small and Nickel eval is sub-10ms on
//     typical envelopes. If this becomes a bottleneck, a follow-up task
//     can batch / cache.
//
//   * The contracts *path* is resolved once at bridge startup
//     (`contractsPath()`), so we don't pay disk lookup on every call.
//
//   * If the `nickel` binary is not on PATH, validation is skipped with
//     a single warning — this keeps coord usable in environments where
//     Nickel isn't installed (contracts still run via the Zig adapter's
//     own gating). To fail closed instead of open, set
//     COORD_REQUIRE_NICKEL=1.
//
//   * Only coord_send and coord_send_gated carry envelope bodies; other
//     coord_* tools are RPC-shaped and skip validation. Extension to
//     more tools is tracked in Appendix K of COORD-MCP-DESIGN-LOG.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { writeFileSync, unlinkSync } from "node:fs";
import { info, warn } from "./logger.js";

const CONTRACTS_REL = "../../cartridges/local-coord-mcp/schemas/coord-messages-contracts.ncl";

let cachedContractsPath = null;
let nickelAvailable = null; // null = not yet probed, true = on PATH, false = missing

/**
 * Resolve the absolute contracts path once and cache it. Returns null
 * if the file isn't found (caller treats as "no validation configured").
 */
export function contractsPath() {
  if (cachedContractsPath !== null) return cachedContractsPath;

  // main.js lives at mcp-bridge/main.js — lib/ is one below.
  const here = dirname(fileURLToPath(import.meta.url));
  const candidate = resolve(here, CONTRACTS_REL);
  cachedContractsPath = existsSync(candidate) ? candidate : null;
  return cachedContractsPath;
}

/** Probe whether \`nickel\` is on PATH. Cached. */
// spawnSync is used intentionally: this is a one-time startup probe with fixed
// args (no user input), so there is no injection risk and event-loop blocking
// is acceptable at bridge initialisation time.
function probeNickel() {
  if (nickelAvailable !== null) return nickelAvailable;
  try {
    const r = spawnSync("nickel", ["--version"], { stdio: "ignore" });
    nickelAvailable = r.status === 0;
  } catch {
    // PermissionDenied (no --allow-run) or binary not found — treat as absent.
    nickelAvailable = false;
  }
  if (!nickelAvailable) {
    const strict = Deno.env.get("COORD_REQUIRE_NICKEL") === "1";
    if (strict) {
      throw new Error("COORD_REQUIRE_NICKEL=1 but `nickel` not on PATH");
    }
    warn("Nickel binary not found — coord envelope validation disabled");
  }
  return nickelAvailable;
}

/**
 * Serialise a JS value into a Nickel literal that `nickel eval` can
 * parse. Covers the subset needed for coord envelopes: null, bool,
 * number (int/float), string, array, plain object. Other shapes are
 * serialised as their JSON form, which Nickel parses as records.
 */
function toNickel(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "boolean") return v ? "true" : "false";
  if (typeof v === "number") {
    // Nickel accepts "1" and "1.5" literals directly.
    return Number.isFinite(v) ? String(v) : "null";
  }
  if (typeof v === "string") {
    // Use Nickel's multiline-string safe form via JSON.stringify —
    // Nickel string literal syntax is a superset of JSON's for basic
    // double-quoted strings (no unicode \u escapes unusual to Nickel).
    return JSON.stringify(v);
  }
  if (Array.isArray(v)) {
    return `[${v.map(toNickel).join(",")}]`;
  }
  if (typeof v === "object") {
    const entries = Object.entries(v)
      .filter(([, val]) => val !== undefined)
      .map(([k, val]) => `"${k}" = ${toNickel(val)}`);
    return `{${entries.join(",")}}`;
  }
  // Fallback: unknown type — stringify to JSON so Nickel at least
  // parses it as a string.
  return JSON.stringify(String(v));
}

/**
 * Run contracts.validate on `envelope`. Returns {ok: true} if valid,
 * or {ok: false, error: string} if Nickel rejects the envelope.
 *
 * If Nickel isn't available (and COORD_REQUIRE_NICKEL != 1), returns
 * {ok: true, skipped: true}.
 */
export function validateEnvelope(envelope, senderRole) {
  if (!probeNickel()) return { ok: true, skipped: true };
  const path = contractsPath();
  if (!path) return { ok: true, skipped: true };

  // Attach sender_role into _meta so role-dependent contracts
  // (TierAttestationGate / UrgentDirectRestriction) can evaluate.
  const withMeta = { ...envelope };
  if (senderRole) {
    withMeta._meta = { ...(withMeta._meta || {}), sender_role: senderRole };
  }

  // Write the call-site script to a temp file in the same dir as the
  // contracts so its relative `import` resolves. /tmp is writable and
  // isolated enough; we use an absolute import path so location doesn't matter.
  const tmp = resolve("/tmp", `._boj_validate_${Deno.pid}_${Date.now()}.ncl`);
  const script =
    `let c = import "${path}" in\n` +
    `let e = ${toNickel(withMeta)} in\n` +
    `c.validate e\n`;

  try {
    writeFileSync(tmp, script);
    // spawnSync: fixed arg array (tmp path is process-controlled), no shell interpolation.
    const r = spawnSync("nickel", ["eval", tmp], {
      encoding: "utf8",
    });
    if (r.status === 0) return { ok: true };
    // Nickel writes the violation to stderr; fall back to stdout.
    const err = (r.stderr || r.stdout || "").trim();
    // Squash to the most informative line.
    const firstLine = err.split("\n").find((l) => l.includes("error:")) || err.split("\n")[0] || "validation failed";
    return { ok: false, error: firstLine };
  } catch (e) {
    return { ok: false, error: `nickel invocation failed: ${e.message}` };
  } finally {
    try { unlinkSync(tmp); } catch { /* best-effort cleanup */ }
  }
}

/**
 * Best-effort parse of the coord_send message body — coord envelopes
 * are typically JSON-stringified A2ML envelopes. Returns the parsed
 * object or null if the body isn't JSON-shaped.
 */
export function tryParseEnvelope(msg) {
  if (typeof msg !== "string") return msg && typeof msg === "object" ? msg : null;
  const s = msg.trim();
  if (!s.startsWith("{")) return null; // plain text payload — caller skips validation
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}

/**
 * Initialise validator state at bridge startup. Idempotent.
 * Logs an info line with the resolved state.
 */
export function initValidator() {
  const path = contractsPath();
  const ready = probeNickel();
  info("Nickel validator", {
    nickel: ready ? "available" : "missing",
    contracts: path ? "loaded" : "not_found",
  });
}
