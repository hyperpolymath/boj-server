// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// 007-mcp / ffi / oo7_mcp_ffi.zig
//
// Zig FFI that backs the 007-mcp cartridge. Three responsibilities:
//
//   1. Spawn `just <recipe> <args>` inside the 007-lang worktree,
//      capture stdout+stderr+exit code, return a structured result.
//   2. Track session lifecycle (Fresh → Registered|Degraded → Deregistered)
//      matching the Idris2 ABI in abi/Oo7Mcp/SafeCli.idr.
//   3. Drive the coord-peer handshake on OnEnter and the deregister on
//      OnExit by posting to http://127.0.0.1:7745 (local-coord-mcp).
//      If coord is unreachable the cartridge flips to Degraded and
//      continues to work — recipes still dispatch; only coord ops are
//      suppressed.
//
// The adapter (adapter/oo7_adapter.zig) layers an HTTP REST surface on
// top of this FFI at 127.0.0.1:1066. Bind-address is loopback-only; the
// Idris2 IsLoopback proof is the source of truth.

const std = @import("std");
const builtin = @import("builtin");

// ═══════════════════════════════════════════════════════════════════════
// Constants (must match abi/Oo7Mcp/SafeCli.idr)
// ═══════════════════════════════════════════════════════════════════════

/// CRITICAL: loopback only. The Idris2 ABI IsLoopback proof pins this.
pub const BIND_ADDR = [4]u8{ 127, 0, 0, 1 };
pub const BIND_PORT: u16 = 1066;

/// Coord server URL — cartridge acts as a client during OnEnter/OnExit.
pub const COORD_URL = "http://127.0.0.1:7745";
pub const COORD_REGISTER_URL = COORD_URL ++ "/tools/coord_register";

pub const MAX_TOOL_NAME: usize = 48;
pub const MAX_ARG_STRING: usize = 4096;
pub const MAX_CAPTURE: usize = 1 << 20; // 1 MiB stdout/stderr cap
pub const DEFAULT_TIMEOUT_MS: u32 = 120_000; // 2 minutes

// ═══════════════════════════════════════════════════════════════════════
// Lifecycle state (matches Oo7Mcp.SafeCli.SessionState)
// ═══════════════════════════════════════════════════════════════════════

pub const SessionState = enum(c_int) {
    fresh = 0,
    registered = 1,
    invoking_tool = 2,
    deregistered = 3,
    degraded = 4,
};

// ═══════════════════════════════════════════════════════════════════════
// Tool risk tier (matches Oo7Mcp.SafeCli.ToolRisk + tierToInt encoding)
// ═══════════════════════════════════════════════════════════════════════
//
// Tier 0 — pure read (status, list)
// Tier 1 — logged (runtime reads, tests, builds, lint)
// Tier 2 — light gate (container builds, docs generate, heal)
// Tier 3 — hard gate (rollback, destructive clean, container-run w/ privileged)
// Tier 4 — forbidden for supervised role (none on 007-mcp; reserved)
//
// Declared here so iseriser's `abi-verify` can check the encoding stays
// in sync with `SafeCli.ToolRisk`. Risk enforcement (categoryDefaultRisk
// / riskPromotion) is currently Idris2-only — the Zig dispatcher does
// not yet gate on this enum; wiring is a separate follow-up.

pub const ToolRisk = enum(c_int) {
    tier0 = 0,
    tier1 = 1,
    tier2 = 2,
    tier3 = 3,
    tier4 = 4,
};

/// Session-wide state. Single-instance per adapter process.
var g_state: SessionState = .fresh;
var g_state_mu: std.Thread.Mutex = .{};

/// Coord-peer identity captured on OnEnter. Empty string when Degraded
/// or Fresh. `token` is the session token returned by coord_register.
var g_peer_id_buf: [64]u8 = undefined;
var g_peer_id_len: usize = 0;
var g_coord_token_buf: [64]u8 = undefined;
var g_coord_token_len: usize = 0;

pub fn peerId() []const u8 {
    return g_peer_id_buf[0..g_peer_id_len];
}

pub fn coordToken() []const u8 {
    return g_coord_token_buf[0..g_coord_token_len];
}

pub fn state() SessionState {
    g_state_mu.lock();
    defer g_state_mu.unlock();
    return g_state;
}

fn setState(next: SessionState) void {
    g_state_mu.lock();
    defer g_state_mu.unlock();
    g_state = next;
}

// ═══════════════════════════════════════════════════════════════════════
// Tool-invocation result
// ═══════════════════════════════════════════════════════════════════════

pub const InvokeResult = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
    /// Caller owns these slices. Call `deinit(allocator)` to free them.
    pub fn deinit(self: *InvokeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.stdout = &.{};
        self.stderr = &.{};
    }
};

pub const InvokeError = error{
    SpawnFailed,
    OutputTooLarge,
    ToolUnknown,
    ArgTooLong,
    BadState,
    OutOfMemory,
};

/// Map an MCP tool name to its Justfile recipe name.
/// The mapping is intentionally verbose (no clever regex) so the
/// surface is obvious at review time and easy to extend.
pub fn recipeFor(tool: []const u8) ?[]const u8 {
    // Lifecycle hooks don't map to just recipes — the adapter handles
    // them directly via onEnter / onExit below.
    if (std.mem.eql(u8, tool, "oo7_parse")) return "parse";
    if (std.mem.eql(u8, tool, "oo7_run")) return "run";
    if (std.mem.eql(u8, tool, "oo7_trace")) return "trace";
    if (std.mem.eql(u8, tool, "oo7_demo")) return "demo";
    if (std.mem.eql(u8, tool, "oo7_run_examples")) return "run-examples";

    if (std.mem.eql(u8, tool, "oo7_build")) return "build";
    if (std.mem.eql(u8, tool, "oo7_build_cli")) return "build-cli";
    if (std.mem.eql(u8, tool, "oo7_build_cli_release")) return "build-cli-release";
    if (std.mem.eql(u8, tool, "oo7_build_watch")) return "build-watch";
    if (std.mem.eql(u8, tool, "oo7_release")) return "release";
    if (std.mem.eql(u8, tool, "oo7_clean")) return "clean";
    if (std.mem.eql(u8, tool, "oo7_clean_all")) return "clean-all";

    if (std.mem.eql(u8, tool, "oo7_test")) return "test";
    if (std.mem.eql(u8, tool, "oo7_test_parser")) return "test-parser";
    if (std.mem.eql(u8, tool, "oo7_test_eval")) return "test-eval";
    if (std.mem.eql(u8, tool, "oo7_test_trace")) return "test-trace";
    if (std.mem.eql(u8, tool, "oo7_test_aspect")) return "test-aspect";
    if (std.mem.eql(u8, tool, "oo7_test_filter")) return "test-filter";
    if (std.mem.eql(u8, tool, "oo7_test_verbose")) return "test-verbose";

    if (std.mem.eql(u8, tool, "oo7_check")) return "check";
    if (std.mem.eql(u8, tool, "oo7_ci")) return "ci";
    if (std.mem.eql(u8, tool, "oo7_preflight")) return "preflight";
    if (std.mem.eql(u8, tool, "oo7_fmt")) return "fmt";
    if (std.mem.eql(u8, tool, "oo7_fmt_check")) return "fmt-check";
    if (std.mem.eql(u8, tool, "oo7_lint")) return "lint";

    if (std.mem.eql(u8, tool, "oo7_audit")) return "audit";
    if (std.mem.eql(u8, tool, "oo7_deny")) return "deny";
    if (std.mem.eql(u8, tool, "oo7_outdated")) return "outdated";
    if (std.mem.eql(u8, tool, "oo7_assail")) return "assail";
    if (std.mem.eql(u8, tool, "oo7_doctor")) return "doctor";
    if (std.mem.eql(u8, tool, "oo7_heal")) return "heal";

    if (std.mem.eql(u8, tool, "oo7_contractile_check")) return "contractile-check";
    if (std.mem.eql(u8, tool, "oo7_must_check")) return "must-check";
    if (std.mem.eql(u8, tool, "oo7_must_check_local")) return "must-check-local";
    if (std.mem.eql(u8, tool, "oo7_must_license_present")) return "must-license-present";
    if (std.mem.eql(u8, tool, "oo7_must_no_banned_files")) return "must-no-banned-files";
    if (std.mem.eql(u8, tool, "oo7_must_readme_present")) return "must-readme-present";
    if (std.mem.eql(u8, tool, "oo7_must_spdx_headers")) return "must-spdx-headers";
    if (std.mem.eql(u8, tool, "oo7_trust_verify")) return "trust-verify";
    if (std.mem.eql(u8, tool, "oo7_trust_verify_local")) return "trust-verify-local";
    if (std.mem.eql(u8, tool, "oo7_trust_no_secrets_committed")) return "trust-no-secrets-committed";
    if (std.mem.eql(u8, tool, "oo7_trust_container_images_pinned")) return "trust-container-images-pinned";
    if (std.mem.eql(u8, tool, "oo7_trust_license_content")) return "trust-license-content";
    if (std.mem.eql(u8, tool, "oo7_intend_list")) return "intend-list";
    if (std.mem.eql(u8, tool, "oo7_intend_list_local")) return "intend-list-local";
    if (std.mem.eql(u8, tool, "oo7_dust_status")) return "dust-status";
    if (std.mem.eql(u8, tool, "oo7_dust_status_local")) return "dust-status-local";
    if (std.mem.eql(u8, tool, "oo7_dust_source_rollback")) return "dust-source-rollback";

    if (std.mem.eql(u8, tool, "oo7_verify")) return "verify";
    if (std.mem.eql(u8, tool, "oo7_verify_harvard")) return "verify-harvard";
    if (std.mem.eql(u8, tool, "oo7_verify_template")) return "verify-template";

    if (std.mem.eql(u8, tool, "oo7_grammar_check")) return "grammar-check";
    if (std.mem.eql(u8, tool, "oo7_spec_check")) return "spec-check";

    if (std.mem.eql(u8, tool, "oo7_canonical_proof_suite")) return "canonical-proof-suite";
    if (std.mem.eql(u8, tool, "oo7_v0_differential")) return "v0-differential";
    if (std.mem.eql(u8, tool, "oo7_v1_differential")) return "v1-differential";
    if (std.mem.eql(u8, tool, "oo7_v1_differential_full")) return "v1-differential-full";

    if (std.mem.eql(u8, tool, "oo7_groove_daemon")) return "groove-daemon";
    if (std.mem.eql(u8, tool, "oo7_groove_setup")) return "groove-setup";

    if (std.mem.eql(u8, tool, "oo7_container_build")) return "container-build";
    if (std.mem.eql(u8, tool, "oo7_container_run")) return "container-run";
    if (std.mem.eql(u8, tool, "oo7_container_verify")) return "container-verify";

    if (std.mem.eql(u8, tool, "oo7_docs")) return "docs";
    if (std.mem.eql(u8, tool, "oo7_cookbook")) return "cookbook";
    if (std.mem.eql(u8, tool, "oo7_info")) return "info";
    if (std.mem.eql(u8, tool, "oo7_tour")) return "tour";
    if (std.mem.eql(u8, tool, "oo7_help_me")) return "help-me";
    if (std.mem.eql(u8, tool, "oo7_help")) return "help";
    if (std.mem.eql(u8, tool, "oo7_self_assess")) return "self-assess";

    if (std.mem.eql(u8, tool, "oo7_crg_badge")) return "crg-badge";
    if (std.mem.eql(u8, tool, "oo7_crg_grade")) return "crg-grade";

    return null;
}

// ═══════════════════════════════════════════════════════════════════════
// `just <recipe> <args>` invocation
// ═══════════════════════════════════════════════════════════════════════

/// Run a Justfile recipe in the 007-lang worktree.
/// Caller owns the returned slices — call result.deinit(allocator).
pub fn invokeRecipe(
    allocator: std.mem.Allocator,
    recipe: []const u8,
    argv_extra: []const []const u8,
    worktree: []const u8,
) InvokeError!InvokeResult {
    if (recipe.len == 0 or recipe.len > MAX_TOOL_NAME) return error.ToolUnknown;

    // argv: just <recipe> <...args>
    var argv_list = std.ArrayList([]const u8).initCapacity(allocator, 2 + argv_extra.len) catch return error.OutOfMemory;
    defer argv_list.deinit(allocator);
    argv_list.appendAssumeCapacity("just");
    argv_list.appendAssumeCapacity(recipe);
    for (argv_extra) |a| argv_list.appendAssumeCapacity(a);

    var child = std.process.Child.init(argv_list.items, allocator);
    child.cwd = worktree;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return error.SpawnFailed;

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    child.collectOutput(allocator, &stdout_buf, &stderr_buf, MAX_CAPTURE) catch {
        _ = child.kill() catch {};
        return error.OutputTooLarge;
    };

    const term = child.wait() catch return error.SpawnFailed;
    const exit_code: i32 = switch (term) {
        .Exited => |c| @intCast(c),
        .Signal => |s| -@as(i32, @intCast(s)),
        .Stopped => -1,
        .Unknown => -1,
    };

    return .{
        .exit_code = exit_code,
        .stdout = stdout_buf.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .stderr = stderr_buf.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

// ═══════════════════════════════════════════════════════════════════════
// Lifecycle — OnEnter / OnExit
// ═══════════════════════════════════════════════════════════════════════

pub const EnterResult = struct {
    peer_id: []const u8,
    coord_state: []const u8, // "registered" or "degraded"
    methodology_files: []const []const u8,
    memory_hits: []const []const u8,
    pub fn deinit(self: *EnterResult, allocator: std.mem.Allocator) void {
        for (self.methodology_files) |p| allocator.free(p);
        allocator.free(self.methodology_files);
        for (self.memory_hits) |p| allocator.free(p);
        allocator.free(self.memory_hits);
    }
};

/// OnEnter: register as coord peer (soft-fail to Degraded), load 6a2,
/// run memory auto-lift. Idempotent: re-calling from Registered or
/// Degraded is a no-op that returns the cached peer_id. Re-entering
/// after Deregistered starts a new registration attempt.
///
/// The adapter handles the HTTP framing; this function only does the
/// state transition + the coord POST + the file-system reads.
pub fn onEnter(
    allocator: std.mem.Allocator,
    worktree: []const u8,
    session_hint: []const u8,
) !EnterResult {
    _ = session_hint; // surfaced in future; no state effect today

    const cur = state();
    if (cur == .registered) {
        // Idempotent — return the existing identity and a re-read methodology pack.
        const methodology = try readMethodologyPack(allocator, worktree);
        const memory = try memoryAutolift(allocator, worktree);
        return .{
            .peer_id = peerId(),
            .coord_state = "registered",
            .methodology_files = methodology,
            .memory_hits = memory,
        };
    }
    if (cur == .degraded) {
        // Retry registration so degraded sessions can self-heal when
        // local-coord-mcp becomes reachable again.
        const upgraded = coordRegister(allocator) catch false;
        if (upgraded) {
            setState(.registered);
        } else if (g_peer_id_len == 0) {
            const local_id = "claude-0000@007-lang-local";
            @memcpy(g_peer_id_buf[0..local_id.len], local_id);
            g_peer_id_len = local_id.len;
            g_coord_token_len = 0;
        }

        const methodology = try readMethodologyPack(allocator, worktree);
        const memory = try memoryAutolift(allocator, worktree);
        return .{
            .peer_id = peerId(),
            .coord_state = if (state() == .registered) "registered" else "degraded",
            .methodology_files = methodology,
            .memory_hits = memory,
        };
    }
    if (cur != .fresh and cur != .deregistered) return error.BadState;

    // Try coord_register. Soft-fail to Degraded on any error.
    const registered = coordRegister(allocator) catch |e| blk: {
        std.log.warn("007-mcp: coord_register failed ({}); continuing in Degraded mode", .{e});
        break :blk false;
    };

    if (registered) {
        setState(.registered);
    } else {
        setState(.degraded);
        // Synthesise a local-only peer_id so callers still have a handle.
        const local_id = "claude-0000@007-lang-local";
        @memcpy(g_peer_id_buf[0..local_id.len], local_id);
        g_peer_id_len = local_id.len;
        g_coord_token_len = 0;
    }

    const methodology = try readMethodologyPack(allocator, worktree);
    const memory = try memoryAutolift(allocator, worktree);

    return .{
        .peer_id = peerId(),
        .coord_state = if (state() == .registered) "registered" else "degraded",
        .methodology_files = methodology,
        .memory_hits = memory,
    };
}

pub const ExitResult = struct {
    drift_findings: []const []const u8,
    coord_state: []const u8,
    pub fn deinit(self: *ExitResult, allocator: std.mem.Allocator) void {
        for (self.drift_findings) |p| allocator.free(p);
        allocator.free(self.drift_findings);
    }
};

/// OnExit: drift check, release claims, deregister. Safe from any state
/// (Fresh/Degraded/Registered all honoured).
pub fn onExit(
    allocator: std.mem.Allocator,
    worktree: []const u8,
    reason: []const u8,
) !ExitResult {
    _ = reason;
    const cur = state();

    const findings = try driftCheck(allocator, worktree);

    // Best-effort coord teardown; failure is non-fatal.
    coordDeregister(allocator) catch |e| {
        if (cur == .registered) {
            std.log.warn("007-mcp: coord_deregister failed ({}); proceeding to Deregistered", .{e});
        }
    };

    setState(.deregistered);
    return .{
        .drift_findings = findings,
        .coord_state = "deregistered",
    };
}

// ─── Methodology pack (6a2) ────────────────────────────────────────────

/// Paths relative to the 007-lang worktree root for the 6a2 pack.
/// Kept in sync with MEMORY.md rule: "6a2 = six a2ml files".
pub const METHODOLOGY_PATHS = [_][]const u8{
    ".machine_readable/STATE.a2ml",
    ".machine_readable/META.a2ml",
    ".machine_readable/ECOSYSTEM.a2ml",
    ".machine_readable/6a2/AGENTIC.a2ml",
    ".machine_readable/6a2/NEUROSYM.a2ml",
    ".machine_readable/6a2/PLAYBOOK.a2ml",
};

fn readMethodologyPack(
    allocator: std.mem.Allocator,
    worktree: []const u8,
) ![][]const u8 {
    var out = try allocator.alloc([]const u8, METHODOLOGY_PATHS.len);
    errdefer allocator.free(out);

    for (METHODOLOGY_PATHS, 0..) |rel, i| {
        // We return the relative path; the adapter returns digests rather
        // than embedding the full file so a pack-load does not balloon
        // the MCP response. If the file is missing, the entry is an
        // explicit sentinel like "MISSING::<path>".
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ worktree, rel }) catch rel;
        if (std.fs.path.isAbsolute(full)) {
            std.fs.accessAbsolute(full, .{}) catch {
                const missing = try std.fmt.allocPrint(allocator, "MISSING::{s}", .{rel});
                out[i] = missing;
                continue;
            };
        } else {
            std.fs.cwd().access(full, .{}) catch {
                const missing = try std.fmt.allocPrint(allocator, "MISSING::{s}", .{rel});
                out[i] = missing;
                continue;
            };
        }
        out[i] = try allocator.dupe(u8, rel);
    }
    return out;
}

// ─── Memory auto-lift ──────────────────────────────────────────────────
//
// DD-26 option (b): static-mapping fallback. Reads the tag map A2ML
// (schemas/memory-tag-map.a2ml) at runtime, matches base_tags (repo-
// derived) against the map's tag entries, collects the memory file
// names, dedupes + caps at MAX_HITS.
//
// Swap-in for VeriSimDB (DD-31 Task #7b): replace `readTagMap` with a
// VeriSimDB index query. Everything else (match / dedupe / cap) stays
// the same because the return shape is identical.

pub const MAX_HITS: usize = 8;

/// Repo-derived tags that drive lookups on OnEnter. Mirrors
/// cartridge.ncl :: memory_autolift.base_tags.
pub const BASE_TAGS = [_][]const u8{
    "007",
    "oo7",
    "canonical-proof-suite",
    "coquelicot",
    "m3",
    "dogfooding",
};

/// Candidate locations for the tag-map A2ML file.
/// The first path is the source location in-repo; the second is the
/// installed location in boj-server/cartridges/007-mcp/schemas/.
pub const TAG_MAP_PATHS = [_][]const u8{
    "cartridges/007-mcp/schemas/memory-tag-map.a2ml",
    "schemas/memory-tag-map.a2ml",
    "/var/mnt/eclipse/repos/boj-server/cartridges/007-mcp/schemas/memory-tag-map.a2ml",
};

fn openMaybeAbsolute(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return try std.fs.openFileAbsolute(path, .{});
    }
    return try std.fs.cwd().openFile(path, .{});
}

/// Read the tag map from disk (first candidate that exists wins).
/// Caller owns the returned slice.
fn readTagMap(allocator: std.mem.Allocator, worktree: []const u8) ![]u8 {
    for (TAG_MAP_PATHS) |rel| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full: []const u8 = if (std.fs.path.isAbsolute(rel))
            rel
        else
            std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ worktree, rel }) catch continue;
        const file = openMaybeAbsolute(full) catch continue;
        defer file.close();
        const stat = try file.stat();
        const buf = try allocator.alloc(u8, stat.size);
        errdefer allocator.free(buf);
        _ = try file.readAll(buf);
        return buf;
    }
    return error.FileNotFound;
}

/// Parse the tag map and return memory filenames whose tag appears in
/// `tags`. The map format is:
///   (tag "<tag-name>"
///     (memories "<file>" "<file>" ...))
/// We scan line-by-line:
///  * a `(tag "<name>")` line opens a block; we record whether `<name>`
///    matches any of the requested tags
///  * subsequent `"<file>"` string literals on `(memories ...)` lines
///    are collected for matching tags
///  * any other `(` at column 0 closes the block
///
/// Deduplicates the output, preserving first-seen order; caps at MAX_HITS.
pub fn matchMemories(
    allocator: std.mem.Allocator,
    tag_map: []const u8,
    tags: []const []const u8,
) ![][]const u8 {
    var out_list = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer out_list.deinit(allocator);

    var in_matching_block: bool = false;
    var in_memories: bool = false;

    var line_it = std.mem.splitScalar(u8, tag_map, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, ";")) continue;

        // Token: payload of the line after optional leading `(tag "name"`.
        // When a `(tag "name"` is present we reset block state and update
        // `in_matching_block` from the name. The remaining tail of the
        // line may ALSO carry a `(memories …)` for the single-line form;
        // we continue processing it in the same iteration.
        var payload = line;
        if (std.mem.startsWith(u8, line, "(tag ")) {
            in_memories = false;
            const open_q = std.mem.indexOfScalar(u8, line, '"') orelse continue;
            const rest = line[open_q + 1 ..];
            const close_q = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
            const name = rest[0..close_q];
            in_matching_block = tagMatches(name, tags);
            payload = rest[close_q + 1 ..];
        }

        // Enter memories section if a `(memories` appears anywhere in the
        // payload of a matching block.
        if (in_matching_block) {
            if (std.mem.indexOf(u8, payload, "(memories")) |_| {
                in_memories = true;
            }
        }

        if (!in_memories) continue;

        // Collect every double-quoted substring on the payload as a filename.
        var p: usize = 0;
        while (p < payload.len) : (p += 1) {
            if (payload[p] != '"') continue;
            const start = p + 1;
            const end_rel = std.mem.indexOfScalar(u8, payload[start..], '"') orelse break;
            const file = payload[start .. start + end_rel];
            p = start + end_rel;
            if (file.len == 0) continue;
            // Dedupe.
            var exists = false;
            for (out_list.items) |prev| {
                if (std.mem.eql(u8, prev, file)) {
                    exists = true;
                    break;
                }
            }
            if (!exists and out_list.items.len < MAX_HITS) {
                const dup = try allocator.dupe(u8, file);
                try out_list.append(allocator, dup);
            }
        }
        // Two or more trailing ')' close the memories sexp.
        if (std.mem.endsWith(u8, payload, "))")) in_memories = false;
    }

    return try out_list.toOwnedSlice(allocator);
}

fn tagMatches(name: []const u8, tags: []const []const u8) bool {
    for (tags) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

/// OnEnter memory auto-lift entry point. Graceful-degrade: if the tag
/// map is missing, return an empty slice — the cartridge still works,
/// the caller just gets zero hits.
fn memoryAutolift(
    allocator: std.mem.Allocator,
    worktree: []const u8,
) ![][]const u8 {
    const map = readTagMap(allocator, worktree) catch {
        return try allocator.alloc([]const u8, 0);
    };
    defer allocator.free(map);
    return try matchMemories(allocator, map, &BASE_TAGS);
}

// ─── Drift check ───────────────────────────────────────────────────────

fn driftCheck(
    allocator: std.mem.Allocator,
    worktree: []const u8,
) ![][]const u8 {
    _ = worktree;
    // Skeleton: the adapter runs `just contractile-check` and surfaces
    // failing items as findings. For now we return an empty slice so
    // OnExit is always successful; the wiring is in place for the richer
    // check to replace this body without contract change.
    var out = try allocator.alloc([]const u8, 0);
    _ = &out;
    return out;
}

// ─── Coord client ──────────────────────────────────────────────────────

/// POST coord_register to local-coord-mcp.
/// Returns true only when an HTTP 200 response carries
/// {"success":true,"peer_id":"...","token":"..."}.
fn coordRegister(allocator: std.mem.Allocator) !bool {
    g_peer_id_len = 0;
    g_coord_token_len = 0;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(COORD_REGISTER_URL) catch return false;
    const payload = "{\"client_kind\":\"claude\",\"context\":\"007-lang\"}";

    var headers_buf: [2]std.http.Header = .{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = "007-mcp/0.1 coord-register" },
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const fetch_result = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .extra_headers = &headers_buf,
        .payload = payload,
        .response_writer = &aw.writer,
    }) catch return false;

    if (@intFromEnum(fetch_result.status) != 200) return false;

    const body = aw.writer.buffered();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();

    const obj = if (parsed.value == .object) parsed.value.object else return false;
    const ok_val = obj.get("success") orelse return false;
    if (ok_val != .bool or !ok_val.bool) return false;
    const peer_id_val = obj.get("peer_id") orelse return false;
    const token_val = obj.get("token") orelse return false;
    if (peer_id_val != .string or token_val != .string) return false;

    const peer_id = peer_id_val.string;
    const token = token_val.string;
    if (peer_id.len == 0 or peer_id.len > g_peer_id_buf.len) return false;
    if (token.len == 0 or token.len > g_coord_token_buf.len) return false;

    @memcpy(g_peer_id_buf[0..peer_id.len], peer_id);
    g_peer_id_len = peer_id.len;
    @memcpy(g_coord_token_buf[0..token.len], token);
    g_coord_token_len = token.len;
    return true;
}

/// POST coord_report_outcome to signal a clean session exit.
/// Best-effort: any HTTP or spawn failure is silently ignored — the
/// coord watchdog will expire the peer if this call is lost.
/// Always clears peer_id / token on return regardless of HTTP outcome.
fn coordDeregister(allocator: std.mem.Allocator) !void {
    defer {
        g_peer_id_len = 0;
        g_coord_token_len = 0;
    }

    const token = coordToken();
    if (token.len == 0) return; // nothing was registered

    // Payload: report the session as a successful outcome.
    // Tag "007-mcp-session" is the session's self-reported task label.
    var payload_buf: [256]u8 = undefined;
    const payload = std.fmt.bufPrint(
        &payload_buf,
        "{{\"token\":\"{s}\"," ++
        "\"tag\":\"007-mcp-session\"," ++
        "\"outcome\":\"success\"," ++
        "\"risk_tier\":1," ++
        "\"duration_ms\":0}}",
        .{token},
    ) catch return;

    const report_url = COORD_URL ++ "/tools/coord_report_outcome";

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(report_url) catch return;
    const header_buf = [1]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    // Fire-and-forget: ignore the response body; we only care that the POST
    // was sent before the session tears down.
    _ = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .extra_headers = &header_buf,
        .payload = payload,
        .response_storage = .ignore,
    }) catch {};
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "recipeFor handles a sampling of tool names" {
    try std.testing.expectEqualStrings("parse", recipeFor("oo7_parse").?);
    try std.testing.expectEqualStrings("canonical-proof-suite", recipeFor("oo7_canonical_proof_suite").?);
    try std.testing.expectEqualStrings("dust-source-rollback", recipeFor("oo7_dust_source_rollback").?);
    try std.testing.expect(recipeFor("not_a_real_tool") == null);
    try std.testing.expect(recipeFor("oo7_on_enter") == null); // lifecycle, handled directly
}

test "bind address is loopback" {
    try std.testing.expectEqual(@as(u8, 127), BIND_ADDR[0]);
    try std.testing.expectEqual(@as(u16, 1066), BIND_PORT);
}

test "lifecycle state round-trip" {
    setState(.fresh);
    try std.testing.expectEqual(SessionState.fresh, state());
    setState(.registered);
    try std.testing.expectEqual(SessionState.registered, state());
    setState(.deregistered);
    try std.testing.expectEqual(SessionState.deregistered, state());
    setState(.fresh); // reset for other tests
}

test "onEnter accepts re-entry from deregistered state" {
    setState(.deregistered);
    var enter = try onEnter(std.testing.allocator, ".", "");
    defer enter.deinit(std.testing.allocator);

    try std.testing.expect(enter.peer_id.len > 0);
    try std.testing.expect(std.mem.eql(u8, enter.coord_state, "registered") or std.mem.eql(u8, enter.coord_state, "degraded"));
}

test "matchMemories picks memories from matching tag blocks only" {
    const map =
        \\;; comment line
        \\(memory-tag-map
        \\  (tag "007"
        \\    (memories "feedback_007_dogfood.md" "feedback_007_access_control.md"))
        \\  (tag "coquelicot"
        \\    (memories "reference_coquelicot_and_mathcomp.md"))
        \\  (tag "irrelevant"
        \\    (memories "some_other.md")))
        \\
    ;
    const tags = [_][]const u8{ "007", "coquelicot" };
    const hits = try matchMemories(std.testing.allocator, map, &tags);
    defer {
        for (hits) |h| std.testing.allocator.free(h);
        std.testing.allocator.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 3), hits.len);
    try std.testing.expectEqualStrings("feedback_007_dogfood.md", hits[0]);
    try std.testing.expectEqualStrings("feedback_007_access_control.md", hits[1]);
    try std.testing.expectEqualStrings("reference_coquelicot_and_mathcomp.md", hits[2]);
}

test "matchMemories deduplicates filenames" {
    const map =
        \\(memory-tag-map
        \\  (tag "007" (memories "a.md" "b.md"))
        \\  (tag "oo7" (memories "a.md" "c.md")))
        \\
    ;
    const tags = [_][]const u8{ "007", "oo7" };
    const hits = try matchMemories(std.testing.allocator, map, &tags);
    defer {
        for (hits) |h| std.testing.allocator.free(h);
        std.testing.allocator.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 3), hits.len);
}

test "matchMemories caps at MAX_HITS" {
    const map =
        \\(memory-tag-map
        \\  (tag "flood" (memories "1.md" "2.md" "3.md" "4.md" "5.md" "6.md" "7.md" "8.md" "9.md" "10.md")))
        \\
    ;
    const tags = [_][]const u8{"flood"};
    const hits = try matchMemories(std.testing.allocator, map, &tags);
    defer {
        for (hits) |h| std.testing.allocator.free(h);
        std.testing.allocator.free(hits);
    }
    try std.testing.expectEqual(MAX_HITS, hits.len);
}

test "matchMemories ignores non-matching tag blocks" {
    const map =
        \\(memory-tag-map
        \\  (tag "foo" (memories "foo.md"))
        \\  (tag "bar" (memories "bar.md")))
        \\
    ;
    const tags = [_][]const u8{"nonexistent"};
    const hits = try matchMemories(std.testing.allocator, map, &tags);
    defer {
        for (hits) |h| std.testing.allocator.free(h);
        std.testing.allocator.free(hits);
    }
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
