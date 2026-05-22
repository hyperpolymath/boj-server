// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hetzner_mcp_ffi.zig — C-ABI FFI implementation for hetzner-mcp cartridge.
//
// Implements the state machine defined in HetznerMcp.SafeCloud (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Bearer token (API token) via vault-mcp.
// REST API: https://api.hetzner.cloud/v1/
// Resources: Servers, Images, SSH Keys, Volumes, Firewalls, Networks.
// Per-second rate limiting with configurable limit.
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

/// Hetzner resource categories matching Idris2 HetznerResource encoding.
pub const HetznerResource = enum(c_int) {
    servers = 0,
    images = 1,
    ssh_keys = 2,
    volumes = 3,
    firewalls = 4,
    networks = 5,
};

/// Hetzner action identifiers matching Idris2 HetznerAction encoding.
pub const HetznerAction = enum(c_int) {
    list_servers = 0,
    get_server = 1,
    create_server = 2,
    delete_server = 3,
    power_on = 4,
    power_off = 5,
    reboot = 6,
    list_images = 7,
    list_ssh_keys = 8,
    create_ssh_key = 9,
    list_volumes = 10,
    create_volume = 11,
    attach_volume = 12,
    list_firewalls = 13,
    create_firewall = 14,
    list_networks = 15,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated,
        .err => to == .unauthenticated,
    };
}

/// Map action integer to its resource category integer. Returns -1 for invalid.
fn actionToResource(action: c_int) c_int {
    const a = std.meta.intToEnum(HetznerAction, action) catch return -1;
    return switch (a) {
        .list_servers, .get_server, .create_server, .delete_server, .power_on, .power_off, .reboot => 0,
        .list_images => 1,
        .list_ssh_keys, .create_ssh_key => 2,
        .list_volumes, .create_volume, .attach_volume => 3,
        .list_firewalls, .create_firewall => 4,
        .list_networks => 5,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const DEFAULT_RATE_LIMIT: u32 = 3600;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
    rate_limit_per_hour: u32 = DEFAULT_RATE_LIMIT,
    calls_this_window: u32 = 0,
    server_count: u32 = 0,
    volume_count: u32 = 0,
    firewall_count: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn hetzner_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Authenticate a session. Returns slot index (>= 0) or error (< 0).
/// Error codes: -1 = no free slots.
/// The rate_limit_per_hour parameter configures per-session throttling.
pub export fn hetzner_mcp_authenticate(rate_limit: c_int) c_int {
    const rl: u32 = std.math.cast(u32, rate_limit) orelse DEFAULT_RATE_LIMIT;

    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.rate_limit_per_hour = rl;
            slot.calls_this_window = 0;
            slot.server_count = 0;
            slot.volume_count = 0;
            slot.firewall_count = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Deauthenticate (close) a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = invalid state transition.
pub export fn hetzner_mcp_deauthenticate(slot_idx: c_int) c_int {
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

/// Get current state of a session. Returns state int or -1 if invalid.
pub export fn hetzner_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn hetzner_mcp_throttle(slot_idx: c_int) c_int {
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

/// Clear rate limiting (resume authenticated). Returns 0 on success.
pub export fn hetzner_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    sessions[idx].state = .authenticated;
    sessions[idx].calls_this_window = 0;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn hetzner_mcp_signal_error(slot_idx: c_int) c_int {
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
// C-ABI exports — resource routing and actions
// ---------------------------------------------------------------------------

/// Get the resource category for an action. Returns resource int (0-5) or -1.
pub export fn hetzner_mcp_action_resource(action: c_int) c_int {
    return actionToResource(action);
}

/// Record an API call on a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = not authenticated, -3 = invalid action.
pub export fn hetzner_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    _ = std.meta.intToEnum(HetznerAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;
    sessions[idx].calls_this_window += 1;
    return 0;
}

/// Get API call count for a session. Returns count or -1 if invalid.
pub export fn hetzner_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Update resource counts (server, volume, firewall) for panel display.
/// Returns 0 on success, -1 if invalid slot.
pub export fn hetzner_mcp_set_counts(slot_idx: c_int, servers: c_int, volumes: c_int, firewalls: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx].server_count = std.math.cast(u32, servers) orelse 0;
    sessions[idx].volume_count = std.math.cast(u32, volumes) orelse 0;
    sessions[idx].firewall_count = std.math.cast(u32, firewalls) orelse 0;
    return 0;
}

/// Get server count for a session. Returns count or -1 if invalid.
pub export fn hetzner_mcp_server_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.server_count);
}

/// Get volume count for a session. Returns count or -1 if invalid.
pub export fn hetzner_mcp_volume_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.volume_count);
}

/// Get firewall count for a session. Returns count or -1 if invalid.
pub export fn hetzner_mcp_firewall_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.firewall_count);
}

/// Get total resource category count. Always returns 6.
pub export fn hetzner_mcp_resource_count() c_int {
    return 6;
}

/// Get total action count. Always returns 16.
pub export fn hetzner_mcp_action_count() c_int {
    return 16;
}

/// Reset all sessions (test/debug use only).
pub export fn hetzner_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "hetzner-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "hetzner_list_servers"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_get_server"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_create_server"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_delete_server"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_server_action"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_resize_server"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_list_floating_ips"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_create_floating_ip"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_list_volumes"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_create_volume"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_list_firewalls"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_create_firewall"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_list_ssh_keys"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_create_ssh_key"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_list_images"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_create_snapshot"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_list_networks"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_create_network"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_list_load_balancers"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "hetzner_create_load_balancer"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "authentication lifecycle" {
    hetzner_mcp_reset();

    const slot = hetzner_mcp_authenticate(3600);
    try std.testing.expect(slot >= 0);

    // Should be authenticated (1)
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_session_state(slot));

    // Record an API call (ListServers = 0)
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_call_count(slot));

    // Deauthenticate
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_deauthenticate(slot));
}

test "rate limiting flow" {
    hetzner_mcp_reset();

    const slot = hetzner_mcp_authenticate(100);
    try std.testing.expect(slot >= 0);

    // Throttle
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), hetzner_mcp_session_state(slot));

    // Cannot invoke while rate limited
    try std.testing.expectEqual(@as(c_int, -2), hetzner_mcp_record_call(slot, 0));

    // Unthrottle
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_session_state(slot));
}

test "error and recovery" {
    hetzner_mcp_reset();

    const slot = hetzner_mcp_authenticate(3600);
    try std.testing.expect(slot >= 0);

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), hetzner_mcp_session_state(slot));

    // Recover to unauthenticated
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_deauthenticate(slot));
}

test "resource counts" {
    hetzner_mcp_reset();

    const slot = hetzner_mcp_authenticate(3600);
    try std.testing.expect(slot >= 0);

    // Set counts
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_set_counts(slot, 5, 3, 2));
    try std.testing.expectEqual(@as(c_int, 5), hetzner_mcp_server_count(slot));
    try std.testing.expectEqual(@as(c_int, 3), hetzner_mcp_volume_count(slot));
    try std.testing.expectEqual(@as(c_int, 2), hetzner_mcp_firewall_count(slot));
}

test "invalid transitions rejected" {
    hetzner_mcp_reset();

    const slot = hetzner_mcp_authenticate(3600);
    try std.testing.expect(slot >= 0);

    // Cannot throttle twice
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), hetzner_mcp_throttle(slot));

    // Cannot error from rate_limited
    try std.testing.expectEqual(@as(c_int, -2), hetzner_mcp_signal_error(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_can_transition(1, 3));
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_can_transition(3, 0));

    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_can_transition(0, 3));
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_can_transition(2, 0));
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_can_transition(3, 1));
}

test "action resource routing" {
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_action_resource(0)); // ListServers -> Servers
    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_action_resource(6)); // Reboot -> Servers
    try std.testing.expectEqual(@as(c_int, 1), hetzner_mcp_action_resource(7)); // ListImages -> Images
    try std.testing.expectEqual(@as(c_int, 2), hetzner_mcp_action_resource(8)); // ListSSHKeys -> SSHKeys
    try std.testing.expectEqual(@as(c_int, 3), hetzner_mcp_action_resource(10)); // ListVolumes -> Volumes
    try std.testing.expectEqual(@as(c_int, 4), hetzner_mcp_action_resource(13)); // ListFirewalls -> Firewalls
    try std.testing.expectEqual(@as(c_int, 5), hetzner_mcp_action_resource(15)); // ListNetworks -> Networks
    try std.testing.expectEqual(@as(c_int, -1), hetzner_mcp_action_resource(99)); // invalid
}

test "slot exhaustion" {
    hetzner_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = hetzner_mcp_authenticate(3600);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), hetzner_mcp_authenticate(3600));

    try std.testing.expectEqual(@as(c_int, 0), hetzner_mcp_deauthenticate(slots[0]));
    const new_slot = hetzner_mcp_authenticate(3600);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns hetzner-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("hetzner-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "hetzner_list_servers",
        "hetzner_get_server",
        "hetzner_create_server",
        "hetzner_delete_server",
        "hetzner_server_action",
        "hetzner_resize_server",
        "hetzner_list_floating_ips",
        "hetzner_create_floating_ip",
        "hetzner_list_volumes",
        "hetzner_create_volume",
        "hetzner_list_firewalls",
        "hetzner_create_firewall",
        "hetzner_list_ssh_keys",
        "hetzner_create_ssh_key",
        "hetzner_list_images",
        "hetzner_create_snapshot",
        "hetzner_list_networks",
        "hetzner_create_network",
        "hetzner_list_load_balancers",
        "hetzner_create_load_balancer",
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
    const rc = boj_cartridge_invoke("hetzner_list_servers", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
