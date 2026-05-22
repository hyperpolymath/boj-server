// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// fly_mcp_ffi.zig -- C-ABI FFI implementation for fly-mcp cartridge.
//
// Implements the state machine defined in the Idris2 ABI layer for
// Fly.io Machines API v1 (https://api.machines.dev/v1/).
// Auth: Bearer token. Thread-safe via std.Thread.Mutex.

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

/// Fly.io Machines API action codes (matches Idris2 FlyAction).
pub const FlyAction = enum(c_int) {
    list_apps = 0,
    get_app = 1,
    create_app = 2,
    destroy_app = 3,
    list_machines = 4,
    get_machine = 5,
    start_machine = 6,
    stop_machine = 7,
    list_volumes = 8,
    create_volume = 9,
    list_secrets = 10,
    set_secret = 11,
    delete_secret = 12,
    list_regions = 13,
    allocate_ip = 14,
    release_ip = 15,
};

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
    app_count: c_int = 0,
    machine_count: c_int = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn fly_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Authenticate and open a session. Returns slot index (>= 0) or -1 (no slots).
pub export fn fly_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (0..MAX_SESSIONS) |idx| {
        const slot = &sessions[idx];
        if (!slot.occupied) {
            slot.occupied = true;
            slot.state = .authenticated;
            slot.token_len = 0;
            slot.app_count = 0;
            slot.machine_count = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn fly_mcp_session_close(slot_idx: c_int) c_int {
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
    slot.app_count = 0;
    slot.machine_count = 0;
    return 0;
}

/// Get the current state of a session. Returns state int or -1 if invalid.
pub export fn fly_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    return @intFromEnum(slot.state);
}

/// Transition to rate-limited state. Returns 0 on success.
pub export fn fly_mcp_rate_limit(slot_idx: c_int) c_int {
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
pub export fn fly_mcp_rate_recover(slot_idx: c_int) c_int {
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
pub export fn fly_mcp_signal_error(slot_idx: c_int) c_int {
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
pub export fn fly_mcp_error_recover(slot_idx: c_int) c_int {
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

/// Check if an action requires authentication. Returns 1 (yes) or 0 (no).
pub export fn fly_mcp_action_requires_auth(action: c_int) c_int {
    const act = std.meta.intToEnum(FlyAction, action) catch return 1;
    return switch (act) {
        .list_regions => 0,
        else => 1,
    };
}

/// Get app count for a session. Returns count or -1 if invalid.
pub export fn fly_mcp_app_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    return slot.app_count;
}

/// Get machine count for a session. Returns count or -1 if invalid.
pub export fn fly_mcp_machine_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    return slot.machine_count;
}

/// Set app count for a session. Returns 0 on success.
pub export fn fly_mcp_set_app_count(slot_idx: c_int, count: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    slot.app_count = count;
    return 0;
}

/// Set machine count for a session. Returns 0 on success.
pub export fn fly_mcp_set_machine_count(slot_idx: c_int, count: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.occupied) return -1;
    slot.machine_count = count;
    return 0;
}

/// Reset all sessions (test/debug use only).
pub export fn fly_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "fly-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "fly_list_apps"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_get_app"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_create_app"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_destroy_app"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_list_machines"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_get_machine"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_create_machine"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_start_machine"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_stop_machine"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_restart_machine"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_destroy_machine"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_list_volumes"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_create_volume"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_list_secrets"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_set_secrets"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_delete_secret"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_list_certificates"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_add_certificate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_list_regions"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_allocate_ip"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "fly_release_ip"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {
    fly_mcp_reset();

    const slot = fly_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be authenticated after open
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_session_state(slot));

    // Rate limit then recover
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_rate_limit(slot));
    try std.testing.expectEqual(@as(c_int, 2), fly_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_rate_recover(slot));
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_session_state(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    fly_mcp_reset();

    const slot = fly_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Cannot go authenticated -> unauthenticated -> (already tested via close)
    // Cannot recover from rate_limited to unauthenticated directly
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_rate_limit(slot));
    try std.testing.expectEqual(@as(c_int, -2), fly_mcp_session_close(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_can_transition(1, 2)); // auth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_can_transition(2, 1)); // rate_limited -> auth
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_can_transition(1, 3)); // auth -> error
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_can_transition(3, 0)); // error -> unauth

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_can_transition(0, 2)); // unauth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_can_transition(2, 0)); // rate_limited -> unauth
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_can_transition(3, 1)); // error -> auth

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_can_transition(99, 0));
}

test "slot exhaustion" {
    fly_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (0..MAX_SESSIONS) |idx| {
        slots[idx] = fly_mcp_session_open();
        try std.testing.expect(slots[idx] >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), fly_mcp_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_session_close(slots[0]));
    const new_slot = fly_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

test "action auth requirements" {
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_action_requires_auth(13)); // list_regions
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_action_requires_auth(0)); // list_apps
    try std.testing.expectEqual(@as(c_int, 1), fly_mcp_action_requires_auth(2)); // create_app
}

test "app and machine counters" {
    fly_mcp_reset();

    const slot = fly_mcp_session_open();
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_app_count(slot));
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_set_app_count(slot, 5));
    try std.testing.expectEqual(@as(c_int, 5), fly_mcp_app_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_machine_count(slot));
    try std.testing.expectEqual(@as(c_int, 0), fly_mcp_set_machine_count(slot, 12));
    try std.testing.expectEqual(@as(c_int, 12), fly_mcp_machine_count(slot));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns fly-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("fly-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "fly_list_apps",
        "fly_get_app",
        "fly_create_app",
        "fly_destroy_app",
        "fly_list_machines",
        "fly_get_machine",
        "fly_create_machine",
        "fly_start_machine",
        "fly_stop_machine",
        "fly_restart_machine",
        "fly_destroy_machine",
        "fly_list_volumes",
        "fly_create_volume",
        "fly_list_secrets",
        "fly_set_secrets",
        "fly_delete_secret",
        "fly_list_certificates",
        "fly_add_certificate",
        "fly_list_regions",
        "fly_allocate_ip",
        "fly_release_ip",
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
    const rc = boj_cartridge_invoke("fly_list_apps", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
