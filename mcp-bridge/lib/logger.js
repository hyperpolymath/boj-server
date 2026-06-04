// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Structured logging module
//
// Emits JSON-structured log lines to stderr (stdout is reserved for
// MCP JSON-RPC messages). Log level controlled via BOJ_LOG_LEVEL env.

import { env, stderr } from "./runtime.js";

const LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3, silent: 4 };
let currentLevel = LOG_LEVELS[env.get("BOJ_LOG_LEVEL") ?? "info"] ?? LOG_LEVELS.info;

/**
 * Update the minimum log level at runtime. Used by the MCP
 * `logging/setLevel` handler to honour client-requested verbosity.
 * Unknown levels are ignored (no-op).
 * @param {"debug"|"info"|"warn"|"error"|"silent"} level
 * @returns {boolean} true if the level was recognised and applied
 */
function setLevel(level) {
  if (level in LOG_LEVELS) {
    currentLevel = LOG_LEVELS[level];
    return true;
  }
  return false;
}

/**
 * Emit a structured log entry to stderr.
 * @param {"debug"|"info"|"warn"|"error"} level
 * @param {string} message
 * @param {Record<string, unknown>} [fields]
 */
function log(level, message, fields = {}) {
  if ((LOG_LEVELS[level] ?? 0) < currentLevel) return;
  const entry = {
    ts: new Date().toISOString(),
    level,
    msg: message,
    ...fields,
  };
  stderr.writeSync(JSON.stringify(entry) + "\n");
}

/** @param {string} msg @param {Record<string, unknown>} [fields] */
function debug(msg, fields) { log("debug", msg, fields); }

/** @param {string} msg @param {Record<string, unknown>} [fields] */
function info(msg, fields) { log("info", msg, fields); }

/** @param {string} msg @param {Record<string, unknown>} [fields] */
function warn(msg, fields) { log("warn", msg, fields); }

/** @param {string} msg @param {Record<string, unknown>} [fields] */
function error(msg, fields) { log("error", msg, fields); }

export { debug, error, info, log, setLevel, warn };
