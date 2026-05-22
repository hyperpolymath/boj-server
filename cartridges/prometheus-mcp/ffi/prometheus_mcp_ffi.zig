// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// prometheus_mcp_ffi.zig — C-ABI FFI implementation for prometheus-mcp cartridge.
//
// Implements the state machine defined in PrometheusMcp.SafeRegistry (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Optional Bearer token — Prometheus reads are typically public.
// Actions: InstantQuery, RangeQuery, ListTargets, ListAlerts, ListLabels,
//          LabelValues, GetMetadata, ListSeries
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session authentication/lifecycle state.
pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// Prometheus action identifiers matching Idris2 PrometheusAction encoding.
pub const PrometheusAction = enum(c_int) {
    instant_query = 0,
    range_query = 1,
    list_targets = 2,
    list_alerts = 3,
    list_labels = 4,
    label_values = 5,
    get_metadata = 6,
    list_series = 7,
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
    instant_queries: u32 = 0,
    range_queries: u32 = 0,
    discovery_ops: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

pub export fn prometheus_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

pub export fn prometheus_mcp_authenticate(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.instant_queries = 0;
            slot.range_queries = 0;
            slot.discovery_ops = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn prometheus_mcp_open_anonymous(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .unauthenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.instant_queries = 0;
            slot.range_queries = 0;
            slot.discovery_ops = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn prometheus_mcp_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

pub export fn prometheus_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

pub export fn prometheus_mcp_throttle(slot_idx: c_int) c_int {
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

pub export fn prometheus_mcp_unthrottle(slot_idx: c_int) c_int {
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

pub export fn prometheus_mcp_signal_error(slot_idx: c_int) c_int {
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

pub export fn prometheus_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(PrometheusAction, action) catch return -3;

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
        .instant_query => sessions[idx].instant_queries += 1,
        .range_query => sessions[idx].range_queries += 1,
        .list_targets, .list_alerts, .list_labels, .label_values, .get_metadata, .list_series => sessions[idx].discovery_ops += 1,
    }

    return 0;
}

pub export fn prometheus_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

pub export fn prometheus_mcp_instant_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.instant_queries);
}

pub export fn prometheus_mcp_range_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.range_queries);
}

pub export fn prometheus_mcp_discovery_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.discovery_ops);
}

pub export fn prometheus_mcp_action_count() c_int {
    return 8;
}

pub export fn prometheus_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "prometheus-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "prometheus_query"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "prometheus_query_range"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "prometheus_list_targets"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "prometheus_list_alerts"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "prometheus_list_labels"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "prometheus_label_values"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "prometheus_metadata"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "prometheus_series"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "authenticated session lifecycle" {
    prometheus_mcp_reset();

    const slot = prometheus_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_instant_query_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_close(slot));
}

test "anonymous session lifecycle" {
    prometheus_mcp_reset();

    const slot = prometheus_mcp_open_anonymous(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 1));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_range_query_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_close(slot));
}

test "rate limiting flow" {
    prometheus_mcp_reset();

    const slot = prometheus_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), prometheus_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), prometheus_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_session_state(slot));
}

test "category counting" {
    prometheus_mcp_reset();

    const slot = prometheus_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // InstantQuery (0)
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 0));
    // RangeQuery (1)
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 1));
    // ListTargets (2)
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 2));
    // ListLabels (4)
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_record_call(slot, 4));

    try std.testing.expectEqual(@as(c_int, 4), prometheus_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_instant_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_range_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 2), prometheus_mcp_discovery_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 1), prometheus_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_can_transition(2, 3));
}

test "slot exhaustion" {
    prometheus_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = prometheus_mcp_authenticate(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), prometheus_mcp_authenticate(0));

    try std.testing.expectEqual(@as(c_int, 0), prometheus_mcp_close(slots[0]));
    const new_slot = prometheus_mcp_authenticate(0);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns prometheus-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("prometheus-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "prometheus_query",
        "prometheus_query_range",
        "prometheus_list_targets",
        "prometheus_list_alerts",
        "prometheus_list_labels",
        "prometheus_label_values",
        "prometheus_metadata",
        "prometheus_series",
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
    const rc = boj_cartridge_invoke("prometheus_query", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
