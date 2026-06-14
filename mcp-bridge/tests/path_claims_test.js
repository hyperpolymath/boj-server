// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// Advisory path-claims — overlap detection, normalisation, TTL sweep.
// Run: node --test mcp-bridge/tests/path_claims_test.js

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  register,
  refresh,
  release,
  list,
  pathsOverlap,
  _reset,
} from "../lib/path-claims.js";

test("segment-prefix overlap, not character prefix", () => {
  _reset();
  assert.equal(pathsOverlap("src/a", "src/a/b"), true);
  assert.equal(pathsOverlap("src/a/b", "src/a"), true);
  assert.equal(pathsOverlap("src/a", "src/a"), true);
  assert.equal(pathsOverlap("src/a", "src/abc"), false);
  assert.equal(pathsOverlap("src/a", "lib/a"), false);
});

test("first claim sees no overlaps", () => {
  _reset();
  const r = register({ task: "t1", holder: "peer-a", paths: ["src/foo"] });
  assert.deepEqual(r.overlaps, []);
  assert.deepEqual(r.paths, ["src/foo"]);
});

test("overlapping second claim from a different peer surfaces a warning", () => {
  _reset();
  register({ task: "t1", holder: "peer-a", paths: ["src/foo"] });
  const r = register({
    task: "t2", holder: "peer-b", paths: ["src/foo/bar.js", "docs/x.adoc"],
  });
  assert.equal(r.overlaps.length, 1);
  assert.equal(r.overlaps[0].task, "t1");
  assert.equal(r.overlaps[0].holder, "peer-a");
  assert.deepEqual(r.overlaps[0].with, ["src/foo/bar.js"]);
});

test("non-overlapping concurrent claims are silent", () => {
  _reset();
  register({ task: "t1", holder: "peer-a", paths: ["src/foo"] });
  const r = register({ task: "t2", holder: "peer-b", paths: ["src/bar"] });
  assert.deepEqual(r.overlaps, []);
});

test("re-claim by same holder is not flagged as overlap", () => {
  _reset();
  register({ task: "t1", holder: "peer-a", paths: ["src/foo"] });
  const r = register({ task: "t1", holder: "peer-a", paths: ["src/foo"] });
  assert.deepEqual(r.overlaps, []);
});

test("paths are normalised (trim, backslashes, trailing slash, ./)", () => {
  _reset();
  const r = register({
    task: "t1", holder: "p", paths: ["  src\\foo\\", "./docs/x.md", "//a//b/"],
  });
  assert.deepEqual(r.paths, ["src/foo", "docs/x.md", "/a/b"]);
});

test("non-string / empty paths are dropped", () => {
  _reset();
  const r = register({
    task: "t1", holder: "p", paths: ["src/a", "", null, 42, "  "],
  });
  assert.deepEqual(r.paths, ["src/a"]);
});

test("TTL sweep removes expired claims on next register", () => {
  _reset();
  register({ task: "t1", holder: "peer-a", paths: ["src/foo"], ttl_s: 0.001 });
  const wait = new Promise((r) => setTimeout(r, 10));
  return wait.then(() => {
    const r = register({ task: "t2", holder: "peer-b", paths: ["src/foo"] });
    assert.deepEqual(r.overlaps, [], "expired t1 should not overlap");
    assert.equal(list().find((c) => c.task === "t1"), undefined);
  });
});

test("refresh extends TTL for an existing claim", () => {
  _reset();
  register({ task: "t1", holder: "peer-a", paths: ["src/foo"], ttl_s: 1 });
  assert.equal(refresh("t1", 600), true);
  assert.equal(refresh("nonexistent", 600), false);
});

test("release removes the claim", () => {
  _reset();
  register({ task: "t1", holder: "peer-a", paths: ["src/foo"] });
  assert.equal(release("t1"), true);
  assert.equal(list().length, 0);
  assert.equal(release("t1"), false);
});

test("multiple active claims overlap the new one — all reported", () => {
  _reset();
  // t1 owns the umbrella `src/foo`, t2 owns `lib/qux`. A new t3 that
  // touches a file under each must surface both as overlaps.
  register({ task: "t1", holder: "peer-a", paths: ["src/foo"] });
  register({ task: "t2", holder: "peer-b", paths: ["lib/qux"] });
  const r = register({
    task: "t3", holder: "peer-c", paths: ["src/foo/baz.js", "lib/qux/zot.js"],
  });
  assert.equal(r.overlaps.length, 2);
  const tasks = r.overlaps.map((o) => o.task).sort();
  assert.deepEqual(tasks, ["t1", "t2"]);
});
