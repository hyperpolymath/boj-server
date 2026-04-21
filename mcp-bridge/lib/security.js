// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Security hardening module
//
// Prompt injection detection, rate limiting, input validation, and
// error sanitization. Ported from proven/src/Proven/SafeMCP.idr.

// ===================================================================
// Prompt injection detection
// ===================================================================

// Injection patterns from SafeMCP.idr injectionPatterns list.
// All comparisons are case-insensitive (toLower before matching).
const INJECTION_PATTERNS = [
  // Role/instruction override attempts
  "ignore previous instructions",
  "ignore all previous",
  "disregard your instructions",
  "forget your instructions",
  "new instructions:",
  "system prompt:",
  "you are now",
  "act as if",
  "pretend you are",
  "override your",
  "bypass your",
  "ignore your safety",
  "jailbreak",
  // Markup-based injection (XML tags, chat template tokens)
  "<system>",
  "</system>",
  "[INST]",
  "[/INST]",
  "<<SYS>>",
  "<</SYS>>",
  "### Instruction:",
  "### Human:",
  "### Assistant:",
  // Additional high-risk patterns
  "```system",
  "new role:",
  "act as",
  "DAN mode",
  "developer mode",
  "base64:",
  "eval(",
  "exec(",
];

/**
 * Normalize a string for injection analysis.
 * Strips zero-width characters, normalizes unicode confusables,
 * and collapses whitespace to defeat common bypass techniques.
 * @param {string} s
 * @returns {string}
 */
function normalizeForAnalysis(s) {
  // Strip zero-width characters (U+200B, U+200C, U+200D, U+FEFF, U+00AD)
  let normalized = s.replace(/[\u200B\u200C\u200D\uFEFF\u00AD]/g, "");
  // Normalize common unicode confusables to ASCII equivalents
  const confusables = {
    "\u0430": "a", "\u0435": "e", "\u043E": "o", "\u0440": "p",
    "\u0441": "c", "\u0443": "y", "\u0445": "x", "\u0456": "i",
    "\u0501": "d", "\u051B": "q", "\u0455": "s",
    "\uFF41": "a", "\uFF42": "b", "\uFF43": "c", "\uFF44": "d",
    "\uFF45": "e", "\uFF49": "i", "\uFF4E": "n", "\uFF4F": "o",
    "\uFF50": "p", "\uFF52": "r", "\uFF53": "s", "\uFF54": "t",
    "\uFF55": "u", "\uFF59": "y",
  };
  for (const [confusable, replacement] of Object.entries(confusables)) {
    normalized = normalized.replaceAll(confusable, replacement);
  }
  // Collapse multiple whitespace into single space
  normalized = normalized.replace(/\s+/g, " ");
  return normalized;
}

/**
 * Analyze a string for prompt injection attempts.
 * Returns a confidence level matching SafeMCP.idr analyzeInjection:
 *   "none" | "low" | "medium" | "high" | "critical"
 *
 * @param {string} s
 * @returns {"none"|"low"|"medium"|"high"|"critical"}
 */
function analyzeInjection(s) {
  if (typeof s !== "string") return "none";
  const lower = normalizeForAnalysis(s).toLowerCase();
  const matchedCount = INJECTION_PATTERNS.filter(
    (pat) => lower.includes(pat.toLowerCase())
  ).length;
  const hasXmlTags =
    lower.includes("<system>") || lower.includes("</system>");
  const hasRoleSwitch =
    lower.includes("### human:") || lower.includes("### assistant:");

  if (matchedCount >= 3 || (hasXmlTags && matchedCount >= 1)) return "critical";
  if (matchedCount >= 2 || hasRoleSwitch) return "high";
  if (matchedCount >= 1) return "medium";
  if (hasXmlTags) return "low";
  return "none";
}

/**
 * Scan all string values in an object tree for injection patterns.
 * Returns the highest confidence level found across all values.
 * @param {unknown} obj
 * @param {number} [maxDepth=10]
 * @returns {"none"|"low"|"medium"|"high"|"critical"}
 */
function scanObjectForInjection(obj, maxDepth = 10) {
  if (maxDepth <= 0) return "none";
  let worst = "none";
  const rank = { none: 0, low: 1, medium: 2, high: 3, critical: 4 };

  function visit(val, depth) {
    if (depth <= 0) return;
    if (typeof val === "string") {
      const level = analyzeInjection(val);
      if (rank[level] > rank[worst]) worst = level;
    } else if (Array.isArray(val)) {
      for (const item of val) visit(item, depth - 1);
    } else if (val !== null && typeof val === "object") {
      for (const key of Object.keys(val)) visit(val[key], depth - 1);
    }
  }
  visit(obj, maxDepth);
  return worst;
}

// ===================================================================
// Rate limiter (token bucket)
// ===================================================================

const RATE_LIMIT = parseInt(process.env.BOJ_RATE_LIMIT, 10) || 60;
const RATE_WINDOW_MS = 60_000;

const rateBucket = {
  tokens: RATE_LIMIT,
  lastRefill: Date.now(),
};

/**
 * Token bucket rate limiter.
 * @returns {boolean} true if the call is allowed
 */
function rateLimitAllow() {
  const now = Date.now();
  const elapsed = now - rateBucket.lastRefill;
  if (elapsed > 0) {
    const refill = Math.floor((elapsed / RATE_WINDOW_MS) * RATE_LIMIT);
    rateBucket.tokens = Math.min(RATE_LIMIT, rateBucket.tokens + refill);
    rateBucket.lastRefill = now;
  }
  if (rateBucket.tokens > 0) {
    rateBucket.tokens -= 1;
    return true;
  }
  return false;
}

// ===================================================================
// Input validation
// ===================================================================

const MAX_INPUT_SIZE_BYTES = 1_048_576; // 1 MB

/**
 * Check if serialized size of tool arguments is within bounds.
 * @param {unknown} args
 * @returns {boolean}
 */
function isInputSizeOk(args) {
  try {
    const serialized = JSON.stringify(args);
    return serialized.length <= MAX_INPUT_SIZE_BYTES;
  } catch {
    return false;
  }
}

/**
 * Validate that required string fields are present and are strings.
 * @param {Record<string, unknown>} args
 * @param {string[]} fieldNames
 * @returns {string|null} error message or null if valid
 */
function validateRequiredStrings(args, fieldNames) {
  for (const name of fieldNames) {
    if (args[name] === undefined || args[name] === null) {
      return `Missing required field: ${name}`;
    }
    if (typeof args[name] !== "string") {
      return `Field '${name}' must be a string`;
    }
    if (args[name].length > 65_536) {
      return `Field '${name}' exceeds maximum length (64 KB)`;
    }
  }
  return null;
}

/**
 * Validate a tool name matches expected MCP format.
 * @param {string} name
 * @returns {boolean}
 */
function isValidToolName(name) {
  return (
    typeof name === "string" &&
    name.length > 0 &&
    name.length <= 128 &&
    /^[a-zA-Z0-9_-]+$/.test(name)
  );
}

/**
 * Validate a cartridge name.
 * @param {string} name
 * @returns {boolean}
 */
function isValidCartridgeName(name) {
  return typeof name === "string" && /^[a-z0-9][a-z0-9-]*$/.test(name) && name.length <= 64;
}

// ===================================================================
// Error sanitization
// ===================================================================

/**
 * Sanitize an error message for external consumption.
 * Removes absolute paths, stack traces, and known sensitive patterns.
 * @param {string} message
 * @returns {string}
 */
function sanitizeErrorMessage(message) {
  if (typeof message !== "string") return "Internal error";
  let sanitized = message.replace(/\/[a-zA-Z0-9_./-]{3,}/g, "[path]");
  sanitized = sanitized.replace(/[A-Z]:\\[a-zA-Z0-9_.\\/-]{3,}/g, "[path]");
  sanitized = sanitized.replace(/\s+at\s+.+\(.+\)/g, "");
  sanitized = sanitized.replace(/\s+at\s+.+:\d+:\d+/g, "");
  sanitized = sanitized.replace(/process\.env\.\w+/g, "[env]");
  if (sanitized.length > 500) {
    sanitized = sanitized.slice(0, 500) + "...";
  }
  return sanitized;
}

export {
  INJECTION_PATTERNS,
  RATE_LIMIT,
  analyzeInjection,
  isInputSizeOk,
  isValidCartridgeName,
  isValidToolName,
  normalizeForAnalysis,
  rateLimitAllow,
  sanitizeErrorMessage,
  scanObjectForInjection,
  validateRequiredStrings,
};
