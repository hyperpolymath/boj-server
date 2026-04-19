// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// e2e_coord.ts — End-to-end validation of local-coord-mcp (Task #8).
//
// Spawns the compiled adapter binary, drives a 2-peer flow through the
// REST surface (master + apprentice), exercises the gate + approve
// + reject + claim paths, then restarts the adapter with the same state
// dir and verifies durability replay restores the pending quarantine,
// claim, and peer registry.
//
// Usage:
//   deno run --allow-run --allow-net --allow-read --allow-write --allow-env \
//     cartridges/local-coord-mcp/tests/e2e_coord.ts
//
// Preconditions:
//   - adapter binary built: zig build --build-file adapter/build.zig
//   - port 7745 free on 127.0.0.1
//
// Exit 0 = pass, non-zero = fail.

const ADAPTER = new URL(
  "../adapter/zig-out/bin/local_coord_adapter",
  import.meta.url,
).pathname;
const BASE = "http://127.0.0.1:7745";

const SUP_SECRET = "e2e-test-supervisor-secret-do-not-deploy";

// ─────────────────────────────────────────────────────────────────────
// Utilities
// ─────────────────────────────────────────────────────────────────────

interface CallResult {
  status: number;
  // deno-lint-ignore no-explicit-any
  body: any;
}

async function call(tool: string, body: Record<string, unknown>): Promise<CallResult> {
  const r = await fetch(`${BASE}/tools/${tool}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const text = await r.text();
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { raw: text };
  }
  return { status: r.status, body: parsed };
}

async function waitForBind(maxMs = 3000): Promise<boolean> {
  const start = performance.now();
  while (performance.now() - start < maxMs) {
    try {
      const conn = await Deno.connect({ hostname: "127.0.0.1", port: 7745 });
      conn.close();
      return true;
    } catch {
      await new Promise((r) => setTimeout(r, 50));
    }
  }
  return false;
}

async function waitForUnbind(maxMs = 3000): Promise<void> {
  const start = performance.now();
  while (performance.now() - start < maxMs) {
    try {
      const conn = await Deno.connect({ hostname: "127.0.0.1", port: 7745 });
      conn.close();
      await new Promise((r) => setTimeout(r, 50));
    } catch {
      return;
    }
  }
}

interface Adapter {
  proc: Deno.ChildProcess;
  stop: () => Promise<void>;
}

async function spawnAdapter(stateDir: string): Promise<Adapter> {
  const cmd = new Deno.Command(ADAPTER, {
    env: {
      BOJ_COORD_STATE_DIR: stateDir,
      BOJ_MASTER_TOKEN: SUP_SECRET,
    },
    stdout: "piped",
    stderr: "piped",
  });
  const proc = cmd.spawn();
  const ok = await waitForBind();
  if (!ok) {
    try {
      proc.kill("SIGTERM");
    } catch {
      /* ignore */
    }
    throw new Error("adapter failed to bind 127.0.0.1:7745 within 3s");
  }
  return {
    proc,
    stop: async () => {
      try {
        proc.kill("SIGTERM");
      } catch {
        /* ignore */
      }
      // Adapter has a blocking accept() loop; SIGTERM should end it.
      await proc.status;
      await waitForUnbind();
    },
  };
}

let passed = 0;
let failed = 0;
const failures: string[] = [];

function ok(label: string) {
  passed++;
  console.log(`  ✓ ${label}`);
}

function fail(label: string, detail?: string) {
  failed++;
  failures.push(detail ? `${label}: ${detail}` : label);
  console.log(`  ✗ ${label}${detail ? ` — ${detail}` : ""}`);
}

function assert(cond: boolean, label: string, detail?: string) {
  if (cond) ok(label);
  else fail(label, detail);
}

function assertEq<T>(actual: T, expected: T, label: string) {
  const eq = JSON.stringify(actual) === JSON.stringify(expected);
  if (eq) ok(label);
  else fail(label, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

// ─────────────────────────────────────────────────────────────────────
// Test flow
// ─────────────────────────────────────────────────────────────────────

async function run() {
  const stateDir = await Deno.makeTempDir({ prefix: "boj-coord-e2e-" });
  console.log(`state dir: ${stateDir}`);

  let adapter = await spawnAdapter(stateDir);

  try {
    console.log("\n── Phase 1: baseline peer flow ──");

    // 1. Register A (claude) + promote to master
    const regA = await call("coord_register", {
      client_kind: "claude",
      context: "window-A",
    });
    assert(regA.status === 200 && regA.body.success === true, "register A");
    const tokenA: string = regA.body.token;
    const peerIdA: string = regA.body.peer_id;
    assert(peerIdA.startsWith("claude-") && peerIdA.endsWith("@window-A"), "peer_id A shape");

    // Exercises DD-32 backward-compat: old tool name still works as alias.
    const promoteA = await call("coord_promote_to_supervisor", {
      token: tokenA,
      secret: SUP_SECRET,
    });
    assert(promoteA.status === 200, "promote A to master (via old alias coord_promote_to_supervisor)");

    // 2. Register B (gemini, defaults to apprentice)
    const regB = await call("coord_register", {
      client_kind: "gemini",
      context: "window-B",
    });
    assert(regB.status === 200, "register B");
    const tokenB: string = regB.body.token;
    const peerIdB: string = regB.body.peer_id;
    assert(peerIdB.startsWith("gemini-") && peerIdB.endsWith("@window-B"), "peer_id B shape");

    // 3. Peer list visible to both
    const peers = await call("coord_list_peers", { token: tokenA });
    assertEq(peers.body.peers.length, 2, "2 peers visible");

    // 4. Tier 0 direct send B → A
    const send1 = await call("coord_send", {
      token: tokenB,
      target: peerIdA,
      message: "hello from apprentice",
    });
    assertEq(send1.body.sent, 1, "B→A send count");

    const recv1 = await call("coord_receive", { token: tokenA });
    assertEq(recv1.body.message, "hello from apprentice", "A receives Tier 0");

    console.log("\n── Phase 2: gate / approve ──");

    // 5. Tier 3 gated from B — lands in quarantine
    const gated1 = await call("coord_send_gated", {
      token: tokenB,
      target: peerIdA,
      message: "please commit feature X",
      risk_tier: 3,
    });
    assertEq(gated1.body.status, "quarantined", "Tier 3 from apprentice quarantined");
    const rid1: number = gated1.body.request_id;
    assert(typeof rid1 === "number" && rid1 > 0, "request_id is positive");

    // 6. Supervisor reviews
    const review1 = await call("coord_review", { token: tokenA });
    assertEq(review1.body.entries.length, 1, "1 entry in review queue");
    assertEq(review1.body.entries[0].request_id, rid1, "review entry request_id matches");
    assertEq(review1.body.entries[0].risk_tier, 3, "review entry risk_tier=3");

    const reviewBody1 = await call("coord_review_entry", {
      token: tokenA,
      request_id: rid1,
    });
    assertEq(
      reviewBody1.body.message,
      "please commit feature X",
      "review_entry returns full body",
    );

    // 7. Approve — message delivers to A's inbox
    const approve1 = await call("coord_approve", { token: tokenA, request_id: rid1 });
    assert(approve1.status === 200, "approve");

    const recv2 = await call("coord_receive", { token: tokenA });
    assertEq(recv2.body.message, "please commit feature X", "approved msg delivered");

    // Quarantine empty post-approve
    const reviewPostApprove = await call("coord_review", { token: tokenA });
    assertEq(reviewPostApprove.body.entries.length, 0, "review empty after approve");

    console.log("\n── Phase 3: reject ──");

    // 8. Reject flow
    const gated2 = await call("coord_send_gated", {
      token: tokenB,
      target: peerIdA,
      message: "bad proposal",
      risk_tier: 3,
    });
    const rid2: number = gated2.body.request_id;
    assertEq(gated2.body.status, "quarantined", "second gate → quarantined");

    const reject1 = await call("coord_reject", {
      token: tokenA,
      request_id: rid2,
      reason: "references nonexistent file src/phantom.ts",
    });
    assert(reject1.status === 200, "reject");

    // Not delivered to recipient.
    const recvPostReject = await call("coord_receive", { token: tokenA });
    assertEq(recvPostReject.body.message, null, "rejected msg NOT delivered");

    console.log("\n── Phase 4: claim mutex ──");

    // 9. Claim + contention
    const claimA = await call("coord_claim_task", { token: tokenA, task: "e2e-shared-task" });
    assertEq(claimA.body.message, "granted", "A claims task");

    const claimB = await call("coord_claim_task", { token: tokenB, task: "e2e-shared-task" });
    assertEq(claimB.body.error, "held", "B denied — held by A");

    console.log("\n── Phase 5: apprentice peer cannot bypass gate ──");

    // 10. Apprentice cannot set urgent_direct (enforced in Nickel contracts,
    // but the FFI also rejects master role_hint on register).
    const tryPromoteB = await call("coord_promote_to_master", {
      token: tokenB,
      secret: "wrong-secret",
    });
    assert(
      tryPromoteB.status === 403 || tryPromoteB.status === 409,
      "B with wrong secret rejected",
    );

    // Can't self-assign via register either. Uses new name `master`.
    const tryRegMaster = await call("coord_register", {
      client_kind: "custom",
      role: "master",
    });
    assert(
      tryRegMaster.status === 400 && tryRegMaster.body.success === false,
      "register with role=master rejected",
    );

    // And the old alias still rejected too (DD-32 backward-compat).
    const tryRegSupervisor = await call("coord_register", {
      client_kind: "custom",
      role: "supervisor",
    });
    assert(
      tryRegSupervisor.status === 400 && tryRegSupervisor.body.success === false,
      "register with role=supervisor (alias) also rejected",
    );

    console.log("\n── Phase 6: track-record + affinity ──");

    // 11. Report some outcomes so coord_get_affinities has data
    const r1 = await call("coord_report_outcome", {
      token: tokenA,
      tag: "commit-review",
      outcome: "success",
      risk_tier: 3,
      duration_ms: 1200,
    });
    assert(r1.status === 200, "report outcome 1");

    const r2 = await call("coord_report_outcome", {
      token: tokenB,
      tag: "doc-write",
      outcome: "fail",
      risk_tier: 1,
      duration_ms: 800,
    });
    assert(r2.status === 200, "report outcome 2");

    const aff = await call("coord_get_affinities", { token: tokenA });
    assert(aff.status === 200, "get_affinities ok");
    assert(Array.isArray(aff.body.affinities), "affinities is array");
    assert(aff.body.affinities.length >= 2, "≥ 2 affinity rows");

    console.log("\n── Phase 7: restart + durability replay ──");

    // 12. Leave a pending quarantine, a claim, reported outcomes — then kill.
    const gated3 = await call("coord_send_gated", {
      token: tokenB,
      target: peerIdA,
      message: "should survive restart",
      risk_tier: 3,
    });
    const rid3: number = gated3.body.request_id;
    assertEq(gated3.body.status, "quarantined", "third gate → quarantined");

    await adapter.stop();
    console.log("  ↻ adapter stopped");

    adapter = await spawnAdapter(stateDir);
    console.log("  ↻ adapter respawned with same state dir");

    // 13. Peer registry restored (same tokens valid)
    const peersAfter = await call("coord_list_peers", { token: tokenA });
    assertEq(peersAfter.body.peers.length, 2, "2 peers after restart");
    assert(
      peersAfter.body.peers.some((p: { peer_id: string }) => p.peer_id === peerIdA),
      "peer A present after restart",
    );
    assert(
      peersAfter.body.peers.some((p: { peer_id: string }) => p.peer_id === peerIdB),
      "peer B present after restart",
    );

    // 14. Supervisor authority still A's
    const reviewAfter = await call("coord_review", { token: tokenA });
    assertEq(reviewAfter.body.entries.length, 1, "1 quarantined entry after restart");
    assertEq(reviewAfter.body.entries[0].request_id, rid3, "surviving request_id matches");

    // 15. Full body of surviving quarantined msg
    const bodyAfter = await call("coord_review_entry", { token: tokenA, request_id: rid3 });
    assertEq(bodyAfter.body.message, "should survive restart", "quarantine body survived");

    // 16. Claim still held across restart
    const claimBAfter = await call("coord_claim_task", {
      token: tokenB,
      task: "e2e-shared-task",
    });
    assertEq(claimBAfter.body.error, "held", "B still denied after restart");

    // 17. Affinity data survived (from track_update log replay)
    const affAfter = await call("coord_get_affinities", { token: tokenA });
    assert(
      Array.isArray(affAfter.body.affinities) && affAfter.body.affinities.length >= 2,
      "affinities survived restart",
    );

    // 18. Approve the surviving entry — delivered to A's inbox
    const approveAfter = await call("coord_approve", { token: tokenA, request_id: rid3 });
    assert(approveAfter.status === 200, "approve post-restart");
    const recvFinal = await call("coord_receive", { token: tokenA });
    assertEq(recvFinal.body.message, "should survive restart", "final delivery post-restart");
  } finally {
    await adapter.stop();
    await Deno.remove(stateDir, { recursive: true });
  }

  console.log(`\n───────────────────────────────────────────────`);
  if (failed === 0) {
    console.log(`  ✅  ${passed} assertions passed`);
    Deno.exit(0);
  } else {
    console.log(`  ❌  ${failed} of ${passed + failed} assertions failed:`);
    for (const f of failures) console.log(`     - ${f}`);
    Deno.exit(1);
  }
}

await run();
