// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// docker_hub_mcp_ffi.zig — C-ABI FFI for Docker Hub MCP cartridge.
//
// Implements the auth state machine defined in the Idris2 ABI layer.
// Two-phase authentication: POST /v2/users/login -> JWT bearer token.
// Pull rate limit tracking: 100 (anonymous) / 200 (authenticated) per 6 hours.
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
// Docker Hub action codes (matches Idris2 DockerHubAction)
// ---------------------------------------------------------------------------

pub const DockerHubAction = enum(c_int) {
    search_images = 0,
    get_repository = 1,
    list_tags = 2,
    get_tag = 3,
    list_namespaces = 4,
    get_manifest = 5,
    delete_tag = 6,
    get_rate_limit = 7,
    list_orgs = 8,
    create_repository = 9,
    delete_repository = 10,
    get_dockerfile = 11,
    list_starred = 12,
    star_repository = 13,
    unstar_repository = 14,
    get_user = 15,
};

/// Returns true if the action mutates remote state.
fn isDestructiveAction(action: DockerHubAction) bool {
    return switch (action) {
        .delete_tag, .create_repository, .delete_repository, .star_repository, .unstar_repository => true,
        .search_images, .get_repository, .list_tags, .get_tag, .list_namespaces, .get_manifest, .get_rate_limit, .list_orgs, .get_dockerfile, .list_starred, .get_user => false,
    };
}

/// Returns true if the action can be performed without authentication.
fn actionAllowsAnonymous(action: DockerHubAction) bool {
    return switch (action) {
        .search_images, .get_rate_limit => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const JWT_BUF_SIZE: usize = 2048;

/// Pull rate limit: 200 pulls/6h for authenticated users.
const PULL_RATE_LIMIT_AUTH: u32 = 200;

const SessionSlot = struct {
    active: bool = false,
    state: AuthState = .unauthenticated,
    jwt_buf: [JWT_BUF_SIZE]u8 = .{0} ** JWT_BUF_SIZE,
    jwt_len: usize = 0,
    pulls_remaining: u32 = PULL_RATE_LIMIT_AUTH,
    last_action: c_int = -1,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn docker_hub_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(AuthState, from) catch return 0;
    const t = std.meta.intToEnum(AuthState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Authenticate a session with a JWT token (obtained from POST /v2/users/login).
/// Returns slot index (>= 0) or error (< 0).
/// Error codes: -1 = no free slots, -2 = null/empty JWT.
pub export fn docker_hub_mcp_authenticate(jwt_ptr: ?[*]const u8, jwt_len: c_int) c_int {
    const ptr = jwt_ptr orelse return -2;
    const len: usize = std.math.cast(usize, jwt_len) orelse return -2;
    if (len == 0 or len > JWT_BUF_SIZE) return -2;

    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            @memcpy(slot.jwt_buf[0..len], ptr[0..len]);
            slot.jwt_len = len;
            slot.pulls_remaining = PULL_RATE_LIMIT_AUTH;
            slot.last_action = -1;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close/logout a session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn docker_hub_mcp_session_close(slot_idx: c_int) c_int {
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
pub export fn docker_hub_mcp_session_state(slot_idx: c_int) c_int {
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
pub export fn docker_hub_mcp_execute_action(slot_idx: c_int, action_code: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    const action = std.meta.intToEnum(DockerHubAction, action_code) catch return -4;

    // Check auth requirement
    if (!actionAllowsAnonymous(action) and slot.state != .authenticated) return -2;

    // Check rate limit for pull-consuming actions
    if (slot.state == .rate_limited) return -3;

    _ = isDestructiveAction(action);

    sessions[idx].last_action = action_code;
    return 0;
}

/// Get remaining pull rate limit for a session. Returns count or -1 if invalid.
pub export fn docker_hub_mcp_pull_rate_remaining(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.pulls_remaining);
}

/// Decrement pull rate counter (called after each image pull). Returns remaining or -3 if exhausted.
pub export fn docker_hub_mcp_consume_pull(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    if (slot.pulls_remaining == 0) {
        sessions[idx].state = .rate_limited;
        return -3;
    }

    sessions[idx].pulls_remaining -= 1;
    return @intCast(sessions[idx].pulls_remaining);
}

/// Reset pull rate limit (called when the 6-hour window resets). Returns 0 on success.
pub export fn docker_hub_mcp_pull_rate_reset(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx].pulls_remaining = PULL_RATE_LIMIT_AUTH;
    if (slot.state == .rate_limited) {
        sessions[idx].state = .authenticated;
    }
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn docker_hub_mcp_signal_error(slot_idx: c_int) c_int {
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
pub export fn docker_hub_mcp_recover(slot_idx: c_int) c_int {
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
pub export fn docker_hub_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "docker-hub-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "dockerhub_search_images"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_get_repository"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_list_tags"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_get_tag"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_list_namespaces"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_get_manifest"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_delete_tag"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_get_rate_limit"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_list_orgs"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_create_repository"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_delete_repository"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_get_dockerfile"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_list_starred"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_star_repository"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_unstar_repository"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "dockerhub_get_user"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "two-phase auth lifecycle" {
    docker_hub_mcp_reset();

    const jwt = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test_payload.signature";
    const slot = docker_hub_mcp_authenticate(jwt.ptr, @intCast(jwt.len));
    try std.testing.expect(slot >= 0);

    // Should be authenticated
    try std.testing.expectEqual(@as(c_int, 1), docker_hub_mcp_session_state(slot));

    // Pull rate should be full
    try std.testing.expectEqual(@as(c_int, 200), docker_hub_mcp_pull_rate_remaining(slot));

    // Close session
    try std.testing.expectEqual(@as(c_int, 0), docker_hub_mcp_session_close(slot));
}

test "consume pull decrements rate" {
    docker_hub_mcp_reset();

    const jwt = "eyJ_test_jwt";
    const slot = docker_hub_mcp_authenticate(jwt.ptr, @intCast(jwt.len));
    try std.testing.expect(slot >= 0);

    // Consume a pull
    try std.testing.expectEqual(@as(c_int, 199), docker_hub_mcp_consume_pull(slot));
    try std.testing.expectEqual(@as(c_int, 199), docker_hub_mcp_pull_rate_remaining(slot));

    // Consume another
    try std.testing.expectEqual(@as(c_int, 198), docker_hub_mcp_consume_pull(slot));
}

test "execute action checks auth" {
    docker_hub_mcp_reset();

    const jwt = "eyJ_test_jwt";
    const slot = docker_hub_mcp_authenticate(jwt.ptr, @intCast(jwt.len));
    try std.testing.expect(slot >= 0);

    // SearchImages (action 0) works
    try std.testing.expectEqual(@as(c_int, 0), docker_hub_mcp_execute_action(slot, 0));

    // ListTags (action 2) works when authenticated
    try std.testing.expectEqual(@as(c_int, 0), docker_hub_mcp_execute_action(slot, 2));
}

test "error and recovery" {
    docker_hub_mcp_reset();

    const jwt = "eyJ_test_jwt";
    const slot = docker_hub_mcp_authenticate(jwt.ptr, @intCast(jwt.len));
    try std.testing.expect(slot >= 0);

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), docker_hub_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), docker_hub_mcp_session_state(slot));

    // Recover
    try std.testing.expectEqual(@as(c_int, 0), docker_hub_mcp_recover(slot));
    try std.testing.expectEqual(@as(c_int, 1), docker_hub_mcp_session_state(slot));
}

test "null jwt rejected" {
    docker_hub_mcp_reset();
    try std.testing.expectEqual(@as(c_int, -2), docker_hub_mcp_authenticate(null, 0));
}

test "slot exhaustion" {
    docker_hub_mcp_reset();

    const jwt = "eyJ_test_jwt";
    var slot_count: usize = 0;
    while (slot_count < MAX_SESSIONS) : (slot_count += 1) {
        const s = docker_hub_mcp_authenticate(jwt.ptr, @intCast(jwt.len));
        try std.testing.expect(s >= 0);
    }

    // Next should fail
    try std.testing.expectEqual(@as(c_int, -1), docker_hub_mcp_authenticate(jwt.ptr, @intCast(jwt.len)));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns docker-hub-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("docker-hub-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "dockerhub_search_images",
        "dockerhub_get_repository",
        "dockerhub_list_tags",
        "dockerhub_get_tag",
        "dockerhub_list_namespaces",
        "dockerhub_get_manifest",
        "dockerhub_delete_tag",
        "dockerhub_get_rate_limit",
        "dockerhub_list_orgs",
        "dockerhub_create_repository",
        "dockerhub_delete_repository",
        "dockerhub_get_dockerfile",
        "dockerhub_list_starred",
        "dockerhub_star_repository",
        "dockerhub_unstar_repository",
        "dockerhub_get_user",
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
    const rc = boj_cartridge_invoke("dockerhub_search_images", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
