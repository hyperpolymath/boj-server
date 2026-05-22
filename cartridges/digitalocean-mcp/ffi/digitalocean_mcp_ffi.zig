// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// digitalocean_mcp_ffi.zig — C-ABI FFI for DigitalOcean MCP cartridge.
//
// Implements the auth state machine defined in the Idris2 ABI layer.
// Bearer token authentication, 5000 req/hour rate limit tracking.
// Thread-safe via std.Thread.Mutex. No heap allocations for results.

const std = @import("std");

// ---------------------------------------------------------------------------
// Auth state machine (matches Idris2 ABI: Unauthenticated/Authenticated/RateLimited/Error)
// ---------------------------------------------------------------------------

pub const AuthState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// Validate whether a transition between two auth states is permitted.
fn isValidTransition(from: AuthState, to: AuthState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .rate_limited or to == .err or to == .unauthenticated,
        .rate_limited => to == .authenticated or to == .err,
        .err => to == .authenticated or to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// DigitalOcean action codes (matches Idris2 DigitaloceanAction)
// ---------------------------------------------------------------------------

pub const DigitaloceanAction = enum(c_int) {
    list_droplets = 0,
    get_droplet = 1,
    create_droplet = 2,
    delete_droplet = 3,
    power_on = 4,
    power_off = 5,
    reboot = 6,
    list_volumes = 7,
    create_volume = 8,
    list_domains = 9,
    create_domain = 10,
    list_ssh_keys = 11,
    list_snapshots = 12,
    create_snapshot = 13,
    list_databases = 14,
    get_account = 15,
};

/// Returns 1 if the action mutates remote state, 0 otherwise.
fn isDestructiveAction(action: DigitaloceanAction) bool {
    return switch (action) {
        .create_droplet, .delete_droplet, .power_on, .power_off, .reboot, .create_volume, .create_domain, .create_snapshot => true,
        .list_droplets, .get_droplet, .list_volumes, .list_domains, .list_ssh_keys, .list_snapshots, .list_databases, .get_account => false,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const TOKEN_BUF_SIZE: usize = 256;

/// Rate limit: 5000 requests per hour for DigitalOcean API.
const RATE_LIMIT_PER_HOUR: u32 = 5000;

const SessionSlot = struct {
    active: bool = false,
    state: AuthState = .unauthenticated,
    token_buf: [TOKEN_BUF_SIZE]u8 = .{0} ** TOKEN_BUF_SIZE,
    token_len: usize = 0,
    requests_remaining: u32 = RATE_LIMIT_PER_HOUR,
    last_action: c_int = -1,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn digitalocean_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(AuthState, from) catch return 0;
    const t = std.meta.intToEnum(AuthState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Authenticate a session with a bearer token. Returns slot index (>= 0) or error (< 0).
/// Error codes: -1 = no free slots, -2 = null/empty token.
pub export fn digitalocean_mcp_authenticate(token_ptr: ?[*]const u8, token_len: c_int) c_int {
    const ptr = token_ptr orelse return -2;
    const len: usize = std.math.cast(usize, token_len) orelse return -2;
    if (len == 0 or len > TOKEN_BUF_SIZE) return -2;

    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            @memcpy(slot.token_buf[0..len], ptr[0..len]);
            slot.token_len = len;
            slot.requests_remaining = RATE_LIMIT_PER_HOUR;
            slot.last_action = -1;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close/logout a session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn digitalocean_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .unauthenticated)) return -2;

    sessions[idx] = SessionSlot{};
    return 0;
}

/// Get the current auth state of a session. Returns state int or -1 if invalid slot.
pub export fn digitalocean_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Execute an action on a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = not authenticated, -3 = rate limited, -4 = invalid action.
pub export fn digitalocean_mcp_execute_action(slot_idx: c_int, action_code: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    const action = std.meta.intToEnum(DigitaloceanAction, action_code) catch return -4;
    _ = isDestructiveAction(action);

    if (slot.requests_remaining == 0) {
        sessions[idx].state = .rate_limited;
        return -3;
    }

    sessions[idx].requests_remaining -= 1;
    sessions[idx].last_action = action_code;
    return 0;
}

/// Get remaining rate limit for a session. Returns count or -1 if invalid.
pub export fn digitalocean_mcp_rate_limit_remaining(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.requests_remaining);
}

/// Reset rate limit (called when the hourly window resets). Returns 0 on success.
pub export fn digitalocean_mcp_rate_limit_reset(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx].requests_remaining = RATE_LIMIT_PER_HOUR;
    if (slot.state == .rate_limited) {
        sessions[idx].state = .authenticated;
    }
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn digitalocean_mcp_signal_error(slot_idx: c_int) c_int {
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

/// Recover from error back to authenticated. Returns 0 on success.
pub export fn digitalocean_mcp_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .err) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

/// Reset all sessions (test/debug use only).
pub export fn digitalocean_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "digitalocean-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "digitalocean_list_droplets"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_get_droplet"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_create_droplet"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_delete_droplet"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_droplet_action"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_list_volumes"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_create_volume"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_list_domains"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_create_domain"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_list_ssh_keys"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_list_snapshots"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_create_snapshot"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_list_databases"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_list_firewalls"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_create_firewall"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_list_load_balancers"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_get_account"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "digitalocean_get_balance"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "authenticate and close lifecycle" {
    digitalocean_mcp_reset();

    const token = "dop_v1_test_token_abc123";
    const slot = digitalocean_mcp_authenticate(token.ptr, @intCast(token.len));
    try std.testing.expect(slot >= 0);

    // Should be authenticated
    try std.testing.expectEqual(@as(c_int, 1), digitalocean_mcp_session_state(slot));

    // Rate limit should be full
    try std.testing.expectEqual(@as(c_int, 5000), digitalocean_mcp_rate_limit_remaining(slot));

    // Close session
    try std.testing.expectEqual(@as(c_int, 0), digitalocean_mcp_session_close(slot));
}

test "execute action decrements rate limit" {
    digitalocean_mcp_reset();

    const token = "dop_v1_test";
    const slot = digitalocean_mcp_authenticate(token.ptr, @intCast(token.len));
    try std.testing.expect(slot >= 0);

    // Execute ListDroplets (action 0)
    try std.testing.expectEqual(@as(c_int, 0), digitalocean_mcp_execute_action(slot, 0));
    try std.testing.expectEqual(@as(c_int, 4999), digitalocean_mcp_rate_limit_remaining(slot));

    // Execute GetAccount (action 15)
    try std.testing.expectEqual(@as(c_int, 0), digitalocean_mcp_execute_action(slot, 15));
    try std.testing.expectEqual(@as(c_int, 4998), digitalocean_mcp_rate_limit_remaining(slot));
}

test "invalid transitions rejected" {
    digitalocean_mcp_reset();

    const token = "dop_v1_test";
    const slot = digitalocean_mcp_authenticate(token.ptr, @intCast(token.len));
    try std.testing.expect(slot >= 0);

    // Cannot go from authenticated to rate_limited directly via transition check
    // (rate limiting happens via execute_action)
    try std.testing.expectEqual(@as(c_int, 1), digitalocean_mcp_can_transition(1, 2)); // auth -> rate_limited: valid

    // Cannot go from unauthenticated to error
    try std.testing.expectEqual(@as(c_int, 0), digitalocean_mcp_can_transition(0, 3));
}

test "error and recovery" {
    digitalocean_mcp_reset();

    const token = "dop_v1_test";
    const slot = digitalocean_mcp_authenticate(token.ptr, @intCast(token.len));
    try std.testing.expect(slot >= 0);

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), digitalocean_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), digitalocean_mcp_session_state(slot));

    // Recover
    try std.testing.expectEqual(@as(c_int, 0), digitalocean_mcp_recover(slot));
    try std.testing.expectEqual(@as(c_int, 1), digitalocean_mcp_session_state(slot));
}

test "null token rejected" {
    digitalocean_mcp_reset();
    try std.testing.expectEqual(@as(c_int, -2), digitalocean_mcp_authenticate(null, 0));
}

test "slot exhaustion" {
    digitalocean_mcp_reset();

    const token = "dop_v1_test";
    var slot_count: usize = 0;
    while (slot_count < MAX_SESSIONS) : (slot_count += 1) {
        const s = digitalocean_mcp_authenticate(token.ptr, @intCast(token.len));
        try std.testing.expect(s >= 0);
    }

    // Next should fail
    try std.testing.expectEqual(@as(c_int, -1), digitalocean_mcp_authenticate(token.ptr, @intCast(token.len)));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns digitalocean-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("digitalocean-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "digitalocean_list_droplets",
        "digitalocean_get_droplet",
        "digitalocean_create_droplet",
        "digitalocean_delete_droplet",
        "digitalocean_droplet_action",
        "digitalocean_list_volumes",
        "digitalocean_create_volume",
        "digitalocean_list_domains",
        "digitalocean_create_domain",
        "digitalocean_list_ssh_keys",
        "digitalocean_list_snapshots",
        "digitalocean_create_snapshot",
        "digitalocean_list_databases",
        "digitalocean_list_firewalls",
        "digitalocean_create_firewall",
        "digitalocean_list_load_balancers",
        "digitalocean_get_account",
        "digitalocean_get_balance",
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
    const rc = boj_cartridge_invoke("digitalocean_list_droplets", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
