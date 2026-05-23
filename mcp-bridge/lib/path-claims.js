// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Advisory path-claims for local-coord-mcp.
//
// The Zig/Idris backend enforces a task-id mutex; this module layers an
// in-bridge advisory map of `task -> {holder, paths, expires_at}` so
// `coord_claim_task` can return `path_overlap` hints when two active
// claims declare overlapping working-tree paths. Advisory by design:
// the backend is the source of truth for ownership; this module never
// rejects a claim, it only annotates the response.

const _claims = new Map(); // task -> { holder, paths, expires_at_ms }

function normalize(p) {
  if (typeof p !== "string") return null;
  let s = p.trim();
  if (!s) return null;
  s = s.replace(/\\/g, "/");
  while (s.includes("//")) s = s.replace(/\/\//g, "/");
  if (s.endsWith("/") && s.length > 1) s = s.slice(0, -1);
  if (s.startsWith("./")) s = s.slice(2);
  return s;
}

function segments(p) {
  return p.split("/").filter((s) => s !== "" && s !== ".");
}

// Two paths overlap when one is a segment-prefix of the other (or equal).
// `src/a` overlaps `src/a/b` and `src/a`, but NOT `src/abc`.
export function pathsOverlap(a, b) {
  const A = segments(a);
  const B = segments(b);
  const n = Math.min(A.length, B.length);
  for (let i = 0; i < n; i++) if (A[i] !== B[i]) return false;
  return true;
}

function sweep(nowMs = Date.now()) {
  for (const [task, entry] of _claims) {
    if (entry.expires_at_ms && entry.expires_at_ms <= nowMs) _claims.delete(task);
  }
}

/**
 * Register an advisory path-claim and return overlap warnings with
 * other *active* claims (excluding the same task by the same holder).
 *
 * @param {object} args
 * @param {string} args.task    — task identifier (matches backend)
 * @param {string} args.holder  — peer-id from backend response (or "?")
 * @param {string[]} args.paths — working-tree paths claimed
 * @param {number} [args.ttl_s] — bridge-side TTL hint from backend
 * @returns {{paths: string[], overlaps: Array<{task,holder,paths:string[],with:string[]}>}}
 */
export function register({ task, holder, paths, ttl_s }) {
  sweep();
  const norm = Array.isArray(paths)
    ? paths.map(normalize).filter(Boolean)
    : [];
  const overlaps = [];
  for (const [otherTask, other] of _claims) {
    if (otherTask === task && other.holder === holder) continue;
    const hits = [];
    for (const a of norm) {
      for (const b of other.paths) {
        if (pathsOverlap(a, b)) hits.push(a);
      }
    }
    if (hits.length) {
      overlaps.push({
        task: otherTask,
        holder: other.holder,
        paths: other.paths.slice(),
        with: Array.from(new Set(hits)),
      });
    }
  }
  const ttl = typeof ttl_s === "number" && ttl_s > 0 ? ttl_s : 300;
  _claims.set(task, {
    holder,
    paths: norm,
    expires_at_ms: Date.now() + ttl * 1000,
  });
  return { paths: norm, overlaps };
}

/** Refresh the TTL for a task's path-claim (called by coord_progress). */
export function refresh(task, ttl_s) {
  const entry = _claims.get(task);
  if (!entry) return false;
  const ttl = typeof ttl_s === "number" && ttl_s > 0 ? ttl_s : 300;
  entry.expires_at_ms = Date.now() + ttl * 1000;
  return true;
}

/** Release a task's path-claim (called by coord_report_outcome). */
export function release(task) {
  return _claims.delete(task);
}

/** List active path-claims (for tests/observability). */
export function list() {
  sweep();
  return Array.from(_claims.entries()).map(([task, e]) => ({
    task,
    holder: e.holder,
    paths: e.paths.slice(),
    expires_at_ms: e.expires_at_ms,
  }));
}

/** Test-only: wipe state. */
export function _reset() {
  _claims.clear();
}
