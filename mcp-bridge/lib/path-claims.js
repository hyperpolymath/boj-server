// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Advisory path-claims for local-coord-mcp.
//
// The Zig/Idris backend enforces a task-id mutex; this module layers an
// in-bridge advisory map of `task -> {holder, segs, expires_at}` so
// `coord_claim_task` can return `path_overlap` hints when two active
// claims declare overlapping working-tree paths. Advisory by design:
// the backend is the source of truth for ownership; this module never
// rejects a claim, it only annotates the response.

const DEFAULT_TTL_S = 300;
const _claims = new Map(); // task -> { holder, paths, segs, expires_at_ms }

function normalize(p) {
  if (typeof p !== "string") return null;
  let s = p.trim();
  if (!s) return null;
  s = s.replace(/\\/g, "/").replace(/\/+/g, "/");
  if (s.startsWith("./")) s = s.slice(2);
  if (s.length > 1 && s.endsWith("/")) s = s.slice(0, -1);
  return s || null;
}

function toSegments(p) {
  return p.split("/").filter((s) => s !== "" && s !== ".");
}

function segmentPrefixMatch(A, B) {
  const n = Math.min(A.length, B.length);
  for (let i = 0; i < n; i++) if (A[i] !== B[i]) return false;
  return true;
}

// Two paths overlap when one is a segment-prefix of the other (or equal).
// `src/a` overlaps `src/a/b` and `src/a`, but NOT `src/abc`.
// Kept as a stable public helper for tests and external use.
export function pathsOverlap(a, b) {
  return segmentPrefixMatch(toSegments(a), toSegments(b));
}

function sweep(nowMs = Date.now()) {
  for (const [task, entry] of _claims) {
    if (entry.expires_at_ms && entry.expires_at_ms <= nowMs) _claims.delete(task);
  }
}

function ttlMs(ttl_s) {
  return (typeof ttl_s === "number" && ttl_s > 0 ? ttl_s : DEFAULT_TTL_S) * 1000;
}

function normalizePaths(paths) {
  if (!Array.isArray(paths)) return [];
  const out = [];
  for (const p of paths) {
    const n = normalize(p);
    if (n) out.push(n);
  }
  return out;
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
  const norm = normalizePaths(paths);
  const newSegs = norm.map(toSegments);

  const overlaps = [];
  for (const [otherTask, other] of _claims) {
    if (otherTask === task && other.holder === holder) continue;
    const hits = new Set();
    for (let i = 0; i < newSegs.length; i++) {
      const a = newSegs[i];
      for (const b of other.segs) {
        if (segmentPrefixMatch(a, b)) {
          hits.add(norm[i]);
          break;
        }
      }
    }
    if (hits.size) {
      overlaps.push({
        task: otherTask,
        holder: other.holder,
        paths: other.paths.slice(),
        with: Array.from(hits),
      });
    }
  }

  _claims.set(task, {
    holder,
    paths: norm,
    segs: newSegs,
    expires_at_ms: Date.now() + ttlMs(ttl_s),
  });
  return { paths: norm, overlaps };
}

/** Refresh the TTL for a task's path-claim (called by coord_progress). */
export function refresh(task, ttl_s) {
  const entry = _claims.get(task);
  if (!entry) return false;
  entry.expires_at_ms = Date.now() + ttlMs(ttl_s);
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
