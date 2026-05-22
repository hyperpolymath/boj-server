// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// opam_mcp_ffi.zig — C-ABI FFI implementation for opam-mcp cartridge.
//
// Implements the state machine defined in OpamMcp.SafeRegistry (Idris2 ABI).
// State machine: Active | RateLimited | Error (no auth — fully public registry)
// REST API: https://opam.ocaml.org/api
// Actions: SearchPackages, GetPackage, GetVersion, ListVersions,
//          GetDependencies, GetReverseDependencies, GetMaintainers,
//          GetTags, ListAllPackages, GetOpamFile
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session lifecycle state. opam is fully public — no auth states needed.
/// 0 = Active, 1 = RateLimited, 2 = Error.
pub const SessionState = enum(c_int) {
    active = 0,
    rate_limited = 1,
    err = 2,
};

/// opam action identifiers matching Idris2 OpamAction encoding.
pub const OpamAction = enum(c_int) {
    search_packages = 0,
    get_package = 1,
    get_version = 2,
    list_versions = 3,
    get_dependencies = 4,
    get_reverse_dependencies = 5,
    get_maintainers = 6,
    get_tags = 7,
    list_all_packages = 8,
    get_opam_file = 9,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .active => to == .rate_limited or to == .err,
        .rate_limited => to == .active,
        .err => to == .active,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .active,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
    search_count: u32 = 0,
    package_lookups: u32 = 0,
    dep_queries: u32 = 0,
    revdep_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn opam_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a session (no auth needed). Returns slot index (>= 0) or error (< 0).
pub export fn opam_mcp_open(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .active;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.search_count = 0;
            slot.package_lookups = 0;
            slot.dep_queries = 0;
            slot.revdep_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success.
pub export fn opam_mcp_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

/// Get current state of a session. Returns state int or -1 if invalid.
pub export fn opam_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn opam_mcp_throttle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .rate_limited)) return -2;

    sessions[idx].state = .rate_limited;
    return 0;
}

/// Clear rate limiting. Returns 0 on success.
pub export fn opam_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .active)) return -2;

    sessions[idx].state = .active;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn opam_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    sessions[idx].state = .err;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — action recording and metrics
// ---------------------------------------------------------------------------

/// Record an API call on a session. Returns 0 on success.
pub export fn opam_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(OpamAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state == .rate_limited) return -2;
    if (slot.state == .err) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;

    switch (act) {
        .search_packages => sessions[idx].search_count += 1,
        .get_package, .get_version, .list_versions, .get_opam_file => sessions[idx].package_lookups += 1,
        .get_dependencies => sessions[idx].dep_queries += 1,
        .get_reverse_dependencies => sessions[idx].revdep_queries += 1,
        else => {},
    }

    return 0;
}

/// Get API call count for a session.
pub export fn opam_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get search query count.
pub export fn opam_mcp_search_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.search_count);
}

/// Get package lookup count.
pub export fn opam_mcp_package_lookup_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.package_lookups);
}

/// Get dependency query count.
pub export fn opam_mcp_dep_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.dep_queries);
}

/// Get reverse dependency query count.
pub export fn opam_mcp_revdep_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.revdep_queries);
}

/// Get total action count. Always returns 10.
pub export fn opam_mcp_action_count() c_int {
    return 10;
}

/// Reset all sessions (test/debug use only).
pub export fn opam_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "opam-mcp";
const CARTRIDGE_VERSION_PTR: [*:0]const u8 = "0.1.0";

export fn boj_cartridge_init() callconv(.c) c_int {
    return 0;
}

export fn boj_cartridge_deinit() callconv(.c) void {}

export fn boj_cartridge_name() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_NAME_PTR;
}

export fn boj_cartridge_version() callconv(.c) [*:0]const u8 {
    return CARTRIDGE_VERSION_PTR;
}

/// Dispatch the cartridge.json MCP tools. Grade D Alpha stubs.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "opam_search_packages"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_get_package"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_get_version"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_list_versions"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_get_dependencies"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_get_reverse_dependencies"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_get_maintainers"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_get_tags"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_list_all_packages"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opam_get_opam_file"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {
    opam_mcp_reset();

    const slot = opam_mcp_open(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_search_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_close(slot));
}

test "rate limiting flow" {
    opam_mcp_reset();

    const slot = opam_mcp_open(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), opam_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_session_state(slot));
}

test "error and recovery" {
    opam_mcp_reset();

    const slot = opam_mcp_open(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 2), opam_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), opam_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_close(slot));
}

test "category counting" {
    opam_mcp_reset();

    const slot = opam_mcp_open(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_record_call(slot, 0)); // Search
    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_record_call(slot, 1)); // GetPackage
    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_record_call(slot, 4)); // GetDependencies
    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_record_call(slot, 5)); // GetReverseDeps

    try std.testing.expectEqual(@as(c_int, 4), opam_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_search_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_package_lookup_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_dep_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_revdep_query_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_can_transition(0, 1)); // Active -> RateLimited
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_can_transition(1, 0)); // RateLimited -> Active
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_can_transition(0, 2)); // Active -> Error
    try std.testing.expectEqual(@as(c_int, 1), opam_mcp_can_transition(2, 0)); // Error -> Active
    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_can_transition(1, 2)); // RateLimited -> Error (invalid)
}

test "slot exhaustion" {
    opam_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = opam_mcp_open(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), opam_mcp_open(0));

    try std.testing.expectEqual(@as(c_int, 0), opam_mcp_close(slots[0]));
    const new_slot = opam_mcp_open(0);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns opam-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("opam-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "opam_search_packages",
        "opam_get_package",
        "opam_get_version",
        "opam_list_versions",
        "opam_get_dependencies",
        "opam_get_reverse_dependencies",
        "opam_get_maintainers",
        "opam_get_tags",
        "opam_list_all_packages",
        "opam_get_opam_file",
    };
    for (tools) |t| {
        var len: usize = buf.len;
        const rc = boj_cartridge_invoke(t.ptr, "{}", &buf, &len);
        try std.testing.expectEqual(@as(i32, 0), rc);
        try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "result") != null);
    }
}

test "invoke: unknown tool returns -1" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke: buffer too small returns -3" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("opam_search_packages", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
