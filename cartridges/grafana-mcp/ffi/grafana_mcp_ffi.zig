// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// grafana_mcp_ffi.zig — C-ABI FFI implementation for grafana-mcp cartridge.
//
// Implements the state machine defined in GrafanaMcp.SafeRegistry (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Bearer token required for all Grafana API operations.
// Actions: SearchDashboards, GetDashboard, CreateDashboard, DeleteDashboard,
//          QueryDatasource, ListAlerts, CreateAnnotation, ListDatasources,
//          ListFolders, Health
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

/// Grafana action identifiers matching Idris2 GrafanaAction encoding.
pub const GrafanaAction = enum(c_int) {
    search_dashboards = 0,
    get_dashboard = 1,
    create_dashboard = 2,
    delete_dashboard = 3,
    query_datasource = 4,
    list_alerts = 5,
    create_annotation = 6,
    list_datasources = 7,
    list_folders = 8,
    health = 9,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
/// Grafana requires auth for all ops, but we allow anonymous -> auth transitions.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated or to == .err,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated,
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
    dashboard_ops: u32 = 0,
    query_count: u32 = 0,
    alert_checks: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn grafana_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open an authenticated session. Returns slot index (>= 0) or error (< 0).
/// Error codes: -1 = no free slots.
pub export fn grafana_mcp_authenticate(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.dashboard_ops = 0;
            slot.query_count = 0;
            slot.alert_checks = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success.
/// Error codes: -1 = invalid slot.
pub export fn grafana_mcp_close(slot_idx: c_int) c_int {
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
pub export fn grafana_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn grafana_mcp_throttle(slot_idx: c_int) c_int {
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
pub export fn grafana_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn grafana_mcp_signal_error(slot_idx: c_int) c_int {
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
/// Error codes: -1 = invalid slot, -2 = rate limited/error state, -3 = invalid action.
pub export fn grafana_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(GrafanaAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state == .rate_limited) return -2;
    if (slot.state == .err) return -2;
    if (slot.state == .unauthenticated) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;

    // Track category-specific counts
    switch (act) {
        .search_dashboards, .get_dashboard, .create_dashboard, .delete_dashboard => sessions[idx].dashboard_ops += 1,
        .query_datasource => sessions[idx].query_count += 1,
        .list_alerts => sessions[idx].alert_checks += 1,
        else => {},
    }

    return 0;
}

/// Get API call count for a session. Returns count or -1 if invalid.
pub export fn grafana_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get dashboard operation count. Returns count or -1 if invalid.
pub export fn grafana_mcp_dashboard_op_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.dashboard_ops);
}

/// Get datasource query count. Returns count or -1 if invalid.
pub export fn grafana_mcp_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.query_count);
}

/// Get alert check count. Returns count or -1 if invalid.
pub export fn grafana_mcp_alert_check_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.alert_checks);
}

/// Get total action count. Always returns 10.
pub export fn grafana_mcp_action_count() c_int {
    return 10;
}

/// Reset all sessions (test/debug use only).
pub export fn grafana_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "grafana-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "grafana_search_dashboards"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_get_dashboard"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_create_dashboard"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_delete_dashboard"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_query_datasource"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_list_alerts"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_create_annotation"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_list_datasources"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_list_folders"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "grafana_health"))
        "{\"result\":{\"health\":\"healthy\",\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "authenticated session lifecycle" {
    grafana_mcp_reset();

    const slot = grafana_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // Should be authenticated (1)
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_session_state(slot));

    // Record a dashboard search (action 0)
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_dashboard_op_count(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_close(slot));
}

test "rate limiting flow" {
    grafana_mcp_reset();

    const slot = grafana_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // Throttle
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), grafana_mcp_session_state(slot));

    // Cannot invoke while rate limited
    try std.testing.expectEqual(@as(c_int, -2), grafana_mcp_record_call(slot, 0));

    // Unthrottle
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_session_state(slot));
}

test "error and recovery" {
    grafana_mcp_reset();

    const slot = grafana_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), grafana_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, -2), grafana_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_close(slot));
}

test "category counting" {
    grafana_mcp_reset();

    const slot = grafana_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // SearchDashboards (0)
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_record_call(slot, 0));
    // GetDashboard (1)
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_record_call(slot, 1));
    // QueryDatasource (4)
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_record_call(slot, 4));
    // ListAlerts (5)
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_record_call(slot, 5));

    try std.testing.expectEqual(@as(c_int, 4), grafana_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 2), grafana_mcp_dashboard_op_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_alert_check_count(slot));
}

test "transition validator" {
    // Unauthenticated -> Authenticated
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_can_transition(0, 1));
    // Authenticated -> Unauthenticated
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_can_transition(1, 0));
    // Authenticated -> RateLimited
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_can_transition(1, 2));
    // RateLimited -> Authenticated
    try std.testing.expectEqual(@as(c_int, 1), grafana_mcp_can_transition(2, 1));
    // Invalid: Unauthenticated -> RateLimited (Grafana requires auth)
    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_can_transition(0, 2));
}

test "slot exhaustion" {
    grafana_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = grafana_mcp_authenticate(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), grafana_mcp_authenticate(0));

    try std.testing.expectEqual(@as(c_int, 0), grafana_mcp_close(slots[0]));
    const new_slot = grafana_mcp_authenticate(0);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns grafana-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("grafana-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "grafana_search_dashboards",
        "grafana_get_dashboard",
        "grafana_create_dashboard",
        "grafana_delete_dashboard",
        "grafana_query_datasource",
        "grafana_list_alerts",
        "grafana_create_annotation",
        "grafana_list_datasources",
        "grafana_list_folders",
        "grafana_health",
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
    const rc = boj_cartridge_invoke("grafana_search_dashboards", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
