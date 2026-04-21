// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Smoke test for the Nickel envelope validator (Task #17).
// Run: node mcp-bridge/lib/nickel-validator.test.js
//
// Verifies:
//   1. contractsPath() resolves to the real file.
//   2. A valid envelope passes.
//   3. A tier-2 envelope without context_fetch_id is rejected.
//   4. urgent_direct from a supervised peer is rejected.

import { strict as assert } from "node:assert";
import { contractsPath, validateEnvelope, initValidator } from "./nickel-validator.js";

let passed = 0;
let failed = 0;

function t(name, fn) {
  try {
    fn();
    console.log(`  PASS: ${name}`);
    passed++;
  } catch (e) {
    console.error(`  FAIL: ${name}\n    ${e.message}`);
    failed++;
  }
}

console.log("=== Nickel validator smoke tests ===");

initValidator();

t("contractsPath resolves", () => {
  const p = contractsPath();
  assert.ok(p, "expected a resolved path, got null");
  assert.ok(p.endsWith("coord-messages-contracts.ncl"), `unexpected path: ${p}`);
});

t("tier 0 status envelope passes", () => {
  const env = {
    version: 1,
    msg_id: "abcdef012345",
    prev_msg_hash: "0".repeat(64),
    sender: "claude-7f3a",
    recipient: "gemini-b2c1",
    timestamp: "2026-04-20T10:00:00Z",
    op_kind: "status",
    risk_tier: 0,
    payload: { status: "ok" },
  };
  const r = validateEnvelope(env, null);
  assert.ok(r.ok, `expected ok, got error: ${r.error}`);
});

t("tier 2 without context_fetch_id is rejected", () => {
  const env = {
    version: 1,
    msg_id: "abcdef012346",
    prev_msg_hash: "0".repeat(64),
    sender: "claude-7f3a",
    recipient: "*",
    timestamp: "2026-04-20T10:00:00Z",
    op_kind: "claim",
    risk_tier: 2,
    payload: { task: "x" },
  };
  const r = validateEnvelope(env, null);
  if (r.skipped) {
    console.log("    (skipped: nickel not on PATH)");
    return;
  }
  assert.ok(!r.ok, "expected rejection, got ok");
});

t("urgent_direct from supervised is rejected", () => {
  const env = {
    version: 1,
    msg_id: "abcdef012347",
    prev_msg_hash: "0".repeat(64),
    sender: "gemini-b2c1",
    recipient: "claude-7f3a",
    timestamp: "2026-04-20T10:00:00Z",
    op_kind: "clarify",
    risk_tier: 0,
    payload: { question: "hey" },
    urgent_direct: true,
  };
  const r = validateEnvelope(env, "supervised");
  if (r.skipped) {
    console.log("    (skipped: nickel not on PATH)");
    return;
  }
  assert.ok(!r.ok, "expected rejection, got ok");
});

console.log(`\n=== ${passed} passed, ${failed} failed ===`);
process.exit(failed === 0 ? 0 : 1);
