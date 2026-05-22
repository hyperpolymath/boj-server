// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hex_mcp_ffi.zig — C-ABI FFI implementation for hex-mcp cartridge.
//
// Implements the state machine defined in HexMcp.SafeRegistry (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Optional API key — most Hex.pm reads are public.
// REST API: https://hex.pm/api
// Actions: SearchPackages, GetPackage, GetRelease, ListReleases, GetDownloads,
//          GetDependencies, GetOwners, GetRetirement, GetUser, ListUserPackages
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session authentication/lifecycle state.
/// 0 = Unauthenticated, 1 = Authenticated, 2 = RateLimited, 3 = Error.
pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// Hex.pm action identifiers matching Idris2 HexAction encoding.
pub const HexAction = enum(c_int) {
    search_packages = 0,
    get_package = 1,
    get_release = 2,
    list_releases = 3,
    get_downloads = 4,
    get_dependencies = 5,
    get_owners = 6,
    get_retirement = 7,
    get_user = 8,
    list_user_packages = 9,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated or to == .rate_limited or to == .err,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated or to == .unauthenticated,
        .err => to == .authenticated or to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
    search_count: u32 = 0,
    package_lookups: u32 = 0,
    dep_queries: u32 = 0,
    owner_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn hex_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open an authenticated session. Returns slot index (>= 0) or error (< 0).
pub export fn hex_mcp_authenticate(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.search_count = 0;
            slot.package_lookups = 0;
            slot.dep_queries = 0;
            slot.owner_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Open an unauthenticated session (read-only public access).
pub export fn hex_mcp_open_anonymous(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .unauthenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.search_count = 0;
            slot.package_lookups = 0;
            slot.dep_queries = 0;
            slot.owner_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success.
pub export fn hex_mcp_close(slot_idx: c_int) c_int {
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
pub export fn hex_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session (429 from Hex.pm). Returns 0 on success.
pub export fn hex_mcp_throttle(slot_idx: c_int) c_int {
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
pub export fn hex_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated) and !isValidTransition(slot.state, .unauthenticated)) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn hex_mcp_signal_error(slot_idx: c_int) c_int {
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
pub export fn hex_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(HexAction, action) catch return -3;

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

    // Track category-specific counts
    switch (act) {
        .search_packages => sessions[idx].search_count += 1,
        .get_package, .get_release, .list_releases, .get_retirement => sessions[idx].package_lookups += 1,
        .get_dependencies => sessions[idx].dep_queries += 1,
        .get_owners => sessions[idx].owner_queries += 1,
        else => {},
    }

    return 0;
}

/// Get API call count for a session.
pub export fn hex_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get search query count.
pub export fn hex_mcp_search_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.search_count);
}

/// Get package lookup count.
pub export fn hex_mcp_package_lookup_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.package_lookups);
}

/// Get dependency query count.
pub export fn hex_mcp_dep_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.dep_queries);
}

/// Get owner query count.
pub export fn hex_mcp_owner_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.owner_queries);
}

/// Get total action count. Always returns 10.
pub export fn hex_mcp_action_count() c_int {
    return 10;
}

/// Reset all sessions (test/debug use only).
pub export fn hex_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "hex-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "hex_search_packages"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_get_package"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_get_release"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_list_releases"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_get_downloads"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_get_dependencies"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_get_owners"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_get_retirement"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_get_user"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hex_list_user_packages"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "authenticated session lifecycle" {
    hex_mcp_reset();

    const slot = hex_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_search_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_close(slot));
}

test "anonymous session lifecycle" {
    hex_mcp_reset();

    const slot = hex_mcp_open_anonymous(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_record_call(slot, 1));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_package_lookup_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_close(slot));
}

test "rate limiting flow" {
    hex_mcp_reset();

    const slot = hex_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), hex_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), hex_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_session_state(slot));
}

test "error and recovery" {
    hex_mcp_reset();

    const slot = hex_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), hex_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), hex_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_close(slot));
}

test "category counting" {
    hex_mcp_reset();

    const slot = hex_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_record_call(slot, 0)); // Search
    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_record_call(slot, 1)); // GetPackage
    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_record_call(slot, 5)); // GetDependencies
    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_record_call(slot, 6)); // GetOwners

    try std.testing.expectEqual(@as(c_int, 4), hex_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_search_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_package_lookup_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_dep_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_owner_query_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 1), hex_mcp_can_transition(3, 0));
    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_can_transition(2, 3));
}

test "slot exhaustion" {
    hex_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = hex_mcp_authenticate(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), hex_mcp_authenticate(0));

    try std.testing.expectEqual(@as(c_int, 0), hex_mcp_close(slots[0]));
    const new_slot = hex_mcp_authenticate(0);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns hex-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("hex-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "hex_search_packages",
        "hex_get_package",
        "hex_get_release",
        "hex_list_releases",
        "hex_get_downloads",
        "hex_get_dependencies",
        "hex_get_owners",
        "hex_get_retirement",
        "hex_get_user",
        "hex_list_user_packages",
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
    const rc = boj_cartridge_invoke("hex_search_packages", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
