// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Bench harness for mcp-bridge/lib/path-claims.js.
//
// Run: node mcp-bridge/tests/path_claims_bench.js
// Or:  just bench-bridge
//
// Path-claims sit on every coord_claim_task call, so the overlap scan
// is on the hot path for multi-agent coordination. Real workloads are
// small (~10-50 active claims), but stress scenarios sanity-check the
// O(n) register scan + the cached segment-split optimisation from the
// post-#142 refactor. Output is stable so commits can be diffed.

import {
  register,
  refresh,
  release,
  list,
  pathsOverlap,
  _reset,
} from "../lib/path-claims.js";

const NS_PER_MS = 1_000_000n;

function bench(name, iters, fn) {
  // Warmup: ~10% of iters or 1k, whichever is smaller.
  const warm = Math.min(iters / 10 | 0, 1000);
  for (let i = 0; i < warm; i++) fn(i);
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < iters; i++) fn(i);
  const t1 = process.hrtime.bigint();
  const totalNs = t1 - t0;
  const nsPerOp = Number(totalNs) / iters;
  const opsPerSec = iters / (Number(totalNs) / 1e9);
  return { name, iters, totalMs: Number(totalNs / NS_PER_MS), nsPerOp, opsPerSec };
}

function fmtRow({ name, iters, totalMs, nsPerOp, opsPerSec }) {
  const ns = nsPerOp < 1000
    ? `${nsPerOp.toFixed(1)} ns/op`
    : nsPerOp < 1_000_000
      ? `${(nsPerOp / 1000).toFixed(2)} µs/op`
      : `${(nsPerOp / 1_000_000).toFixed(2)} ms/op`;
  const ops = opsPerSec > 1e6
    ? `${(opsPerSec / 1e6).toFixed(2)}M ops/s`
    : opsPerSec > 1e3
      ? `${(opsPerSec / 1e3).toFixed(1)}k ops/s`
      : `${opsPerSec.toFixed(0)} ops/s`;
  return `  ${name.padEnd(50)} ${String(iters).padStart(8)} iters  ${String(totalMs).padStart(5)} ms  ${ns.padStart(14)}  ${ops.padStart(14)}`;
}

function seedClaims(n, pathsPerClaim) {
  _reset();
  for (let i = 0; i < n; i++) {
    const paths = [];
    for (let j = 0; j < pathsPerClaim; j++) {
      paths.push(`pkg-${i}/mod-${j}/file-${i}-${j}.js`);
    }
    register({ task: `seed-${i}`, holder: `peer-${i % 5}`, paths, ttl_s: 3600 });
  }
}

const SCENARIOS = [
  // Realistic: 10 active claims, declaring 3 paths each. Typical multi-
  // agent workstation: 3-5 peers, 1-3 claims apiece.
  { name: "register: 10 active claims, 3 new paths", seed: 10, declared: 3, iters: 50_000 },
  // Heavier: 100 claims. Sustained multi-day session.
  { name: "register: 100 active claims, 3 new paths", seed: 100, declared: 3, iters: 20_000 },
  // Stress: 1000 claims. Beyond design point — measures graceful scaling.
  { name: "register: 1000 active claims, 3 new paths", seed: 1000, declared: 3, iters: 5_000 },
  // Wide declared paths (rare but possible — a sweeping refactor).
  { name: "register: 100 active claims, 20 new paths", seed: 100, declared: 20, iters: 5_000 },
];

console.log("path-claims bench  (node " + process.version + ")\n");
console.log("  " + "scenario".padEnd(50) + "    iters       ms        ns/op          ops/s");
console.log("  " + "-".repeat(110));

for (const s of SCENARIOS) {
  seedClaims(s.seed, 3);
  // Pre-build the declared-paths array once so we measure register(),
  // not array construction.
  const declared = [];
  for (let j = 0; j < s.declared; j++) {
    declared.push(`pkg-new/feature/file-${j}.js`);
  }
  // Reuse one task slot — each iter is an update against the same
  // seeded population, so active-claim count stays at s.seed and the
  // overlap-scan cost is what we actually want to measure.
  const result = bench(s.name, s.iters, () => {
    register({
      task: "hot-task",
      holder: "peer-hot",
      paths: declared,
      ttl_s: 3600,
    });
  });
  console.log(fmtRow(result));
}

// Leaf primitive — drives the inner loop in register(). Use long-ish
// paths to exercise the segment comparator under realistic depth.
const aLong = "cartridges/local-coord-mcp/abi/LocalCoord/Identity.idr";
const bLong = "cartridges/local-coord-mcp/abi/LocalCoord/Auth.idr";
const aShort = "src/foo";
const bShort = "src/foo/bar/baz.js";

console.log();
console.log(fmtRow(bench("pathsOverlap: deep diverge at segment 4", 1_000_000, () => {
  pathsOverlap(aLong, bLong);
})));
console.log(fmtRow(bench("pathsOverlap: short prefix match", 1_000_000, () => {
  pathsOverlap(aShort, bShort);
})));

// refresh/release/list — bookkeeping that fires on coord_progress and
// coord_report_outcome. Measure to catch accidental regressions.
seedClaims(100, 3);
console.log();
let r = 0;
console.log(fmtRow(bench("refresh (existing claim)", 100_000, () => {
  refresh(`seed-${r++ % 100}`, 300);
})));
seedClaims(100, 3);
let q = 0;
console.log(fmtRow(bench("list (100 active claims)", 50_000, () => {
  list();
  q++;
})));

console.log("\n  (Bench numbers depend on host; use deltas across commits, not absolute values.)");
