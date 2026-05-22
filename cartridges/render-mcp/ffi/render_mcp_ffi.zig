// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// render_mcp_ffi.zig -- C-ABI FFI implementation for render-mcp cartridge.
//
// Implements the state machine defined in the Idris2 ABI layer for
// Render REST API v1 (https://api.render.com/v1/).
// Auth: Bearer token (API key). Rate limit: 100 req/min.
// Thread-safe via std.Thread.Mutex.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI: Unauthenticated=0, Authenticated=1,
// RateLimited=2, Error=3)
// ---------------------------------------------------------------------------

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// Render REST API action codes (matches Idris2 RenderAction).
pub const RenderAction = enum(c_int) {
    list_services = 0,
    get_service = 1,
    create_service = 2,
    delete_service = 3,
    list_deploys = 4,
    trigger_deploy = 5,
    get_deploy = 6,
    list_env_groups = 7,
    get_env_group = 8,
    list_custom_domains = 9,
    add_custom_domain = 10,
    list_jobs = 11,
    create_job = 12,
    suspend_service = 13,
    resume_service = 14,
    get_bandwidth = 15,
};

/// Render API rate limit: 100 requests per minute.
pub const RATE_LIMIT_PER_MINUTE: c_int = 100;

fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated or to == .err,
        .authenticated => to == .rate_limited or to == .err or to == .unauthenticated,
        .rate_limited => to == .authenticated or to == .err,
        .err => to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const TOKEN_BUF_SIZE: usize = 512;

const SessionSlot = struct {
    occupied: bool = false,
    state: SessionState = .unauthenticated,
    token_buf: [TOKEN_BUF_SIZE]u8 = .{0} ** TOKEN_BUF_SIZE,
    token_len: usize = 0,
    service_count: c_int = 0,
    deploy_ok: c_int = 0,
    deploy_fail: c_int = 0,
    bandwidth_mb: c_int = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn render_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Authenticate and open a session. Returns slot index (>= 0) or -1 (no slots).
pub export fn render_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (0..MAX_SESSIONS) |idx| {
        const slot = &sessions[idx];
        if (!slot.occupied) {
            slot.occupied = true;
            slot.state = .authenticated;
            slot.token_len = 0;
            slot.service_count = 0;
            slot.deploy_ok = 0;
            slot.deploy_fail = 0;
            slot.bandwidth_mb = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn render_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    if (!isValidTransition(slot.state, .unauthenticated)) return -2;

    slot.occupied = false;
    slot.state = .unauthenticated;
    slot.token_len = 0;
    slot.service_count = 0;
    slot.deploy_ok = 0;
    slot.deploy_fail = 0;
    slot.bandwidth_mb = 0;
    return 0;
}

/// Get the current state of a session. Returns state int or -1 if invalid.
pub export fn render_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    return @intFromEnum(slot.state);
}

/// Transition to rate-limited state. Returns 0 on success.
pub export fn render_mcp_rate_limit(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    if (!isValidTransition(slot.state, .rate_limited)) return -2;

    slot.state = .rate_limited;
    return 0;
}

/// Recover from rate-limited back to authenticated. Returns 0 on success.
pub export fn render_mcp_rate_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    slot.state = .authenticated;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn render_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    slot.state = .err;
    return 0;
}

/// Recover from error back to unauthenticated. Returns 0 on success.
pub export fn render_mcp_error_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    if (!isValidTransition(slot.state, .unauthenticated)) return -2;

    slot.state = .unauthenticated;
    return 0;
}

/// All Render actions require auth. Returns 1 always.
pub export fn render_mcp_action_requires_auth(action: c_int) c_int {
    _ = std.meta.intToEnum(RenderAction, action) catch return 1;
    return 1;
}

/// Get the rate limit (requests per minute).
pub export fn render_mcp_rate_limit_per_minute() c_int {
    return RATE_LIMIT_PER_MINUTE;
}

/// Get service count for a session.
pub export fn render_mcp_service_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    return slot.service_count;
}

/// Set service count for a session.
pub export fn render_mcp_set_service_count(slot_idx: c_int, count: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    slot.service_count = count;
    return 0;
}

/// Get successful deploy count.
pub export fn render_mcp_deploy_ok(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    return slot.deploy_ok;
}

/// Get failed deploy count.
pub export fn render_mcp_deploy_fail(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    return slot.deploy_fail;
}

/// Set deploy counts.
pub export fn render_mcp_set_deploy_counts(slot_idx: c_int, ok: c_int, fail: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    slot.deploy_ok = ok;
    slot.deploy_fail = fail;
    return 0;
}

/// Get bandwidth usage in MB.
pub export fn render_mcp_bandwidth_mb(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    return slot.bandwidth_mb;
}

/// Set bandwidth usage in MB.
pub export fn render_mcp_set_bandwidth_mb(slot_idx: c_int, mb: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    slot.bandwidth_mb = mb;
    return 0;
}

/// Reset all sessions (test/debug use only).
pub export fn render_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "render-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "render_list_services"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_get_service"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_create_service"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_delete_service"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_list_deploys"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_trigger_deploy"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_get_deploy"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_list_env_groups"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_get_env_group"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_list_custom_domains"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_add_custom_domain"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_list_jobs"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_create_job"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_suspend_service"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_resume_service"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "render_get_bandwidth"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {
    render_mcp_reset();

    const slot = render_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be authenticated after open
    try std.testing.expectEqual(@as(c_int, 1), render_mcp_session_state(slot));

    // Rate limit then recover
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_rate_limit(slot));
    try std.testing.expectEqual(@as(c_int, 2), render_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_rate_recover(slot));
    try std.testing.expectEqual(@as(c_int, 1), render_mcp_session_state(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    render_mcp_reset();

    const slot = render_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Cannot close while rate-limited
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_rate_limit(slot));
    try std.testing.expectEqual(@as(c_int, -2), render_mcp_session_close(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), render_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), render_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), render_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 1), render_mcp_can_transition(1, 3));
    try std.testing.expectEqual(@as(c_int, 1), render_mcp_can_transition(3, 0));

    try std.testing.expectEqual(@as(c_int, 0), render_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_can_transition(2, 0));
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_can_transition(3, 1));
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_can_transition(99, 0));
}

test "slot exhaustion" {
    render_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (0..MAX_SESSIONS) |idx| {
        slots[idx] = render_mcp_session_open();
        try std.testing.expect(slots[idx] >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), render_mcp_session_open());

    try std.testing.expectEqual(@as(c_int, 0), render_mcp_session_close(slots[0]));
    const new_slot = render_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

test "service and deploy counters" {
    render_mcp_reset();

    const slot = render_mcp_session_open();
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), render_mcp_service_count(slot));
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_set_service_count(slot, 8));
    try std.testing.expectEqual(@as(c_int, 8), render_mcp_service_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), render_mcp_deploy_ok(slot));
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_set_deploy_counts(slot, 15, 3));
    try std.testing.expectEqual(@as(c_int, 15), render_mcp_deploy_ok(slot));
    try std.testing.expectEqual(@as(c_int, 3), render_mcp_deploy_fail(slot));
}

test "bandwidth counter" {
    render_mcp_reset();

    const slot = render_mcp_session_open();
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), render_mcp_bandwidth_mb(slot));
    try std.testing.expectEqual(@as(c_int, 0), render_mcp_set_bandwidth_mb(slot, 1024));
    try std.testing.expectEqual(@as(c_int, 1024), render_mcp_bandwidth_mb(slot));
}

test "rate limit constant" {
    try std.testing.expectEqual(@as(c_int, 100), render_mcp_rate_limit_per_minute());
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns render-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("render-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "render_list_services",
        "render_get_service",
        "render_create_service",
        "render_delete_service",
        "render_list_deploys",
        "render_trigger_deploy",
        "render_get_deploy",
        "render_list_env_groups",
        "render_get_env_group",
        "render_list_custom_domains",
        "render_add_custom_domain",
        "render_list_jobs",
        "render_create_job",
        "render_suspend_service",
        "render_resume_service",
        "render_get_bandwidth",
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
    const rc = boj_cartridge_invoke("render_list_services", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
