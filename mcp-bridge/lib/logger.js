// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Structured logging module
//
// Emits JSON-structured log lines to stderr (stdout is reserved for
// MCP JSON-RPC messages). Log level controlled via BOJ_LOG_LEVEL env.

const LOG_LEVELS = { debug: 0, info: 1, warn: 2, error: 3, silent: 4 };
const currentLevel = LOG_LEVELS[process.env.BOJ_LOG_LEVEL || "info"] ?? LOG_LEVELS.info;

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
  process.stderr.write(JSON.stringify(entry) + "\n");
}

/** @param {string} msg @param {Record<string, unknown>} [fields] */
function debug(msg, fields) { log("debug", msg, fields); }

/** @param {string} msg @param {Record<string, unknown>} [fields] */
function info(msg, fields) { log("info", msg, fields); }

/** @param {string} msg @param {Record<string, unknown>} [fields] */
function warn(msg, fields) { log("warn", msg, fields); }

/** @param {string} msg @param {Record<string, unknown>} [fields] */
function error(msg, fields) { log("error", msg, fields); }

export { debug, error, info, log, warn };
