// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// matrix_mcp_ffi.zig — C-ABI FFI implementation for matrix-mcp cartridge.
//
// Implements the connection state machine and Matrix action dispatch defined
// in the Idris2 ABI layer (MatrixMcp.SafeComms). Thread-safe via
// std.Thread.Mutex. Bearer token auth with configurable homeserver URL.
// Transaction ID generation for idempotent PUT requests.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI: MatrixMcp.SafeComms)
// ---------------------------------------------------------------------------

/// Connection state for Matrix client sessions.
/// Disconnected(0) | Authenticating(1) | Connected(2) | Syncing(3) | Error(4)
pub const ConnState = enum(c_int) {
    disconnected = 0,
    authenticating = 1,
    connected = 2,
    syncing = 3,
    err = 4,
};

/// Check whether a state transition is permitted by the state machine.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .disconnected => to == .authenticating,
        .authenticating => to == .connected or to == .err,
        .connected => to == .syncing or to == .err or to == .disconnected,
        .syncing => to == .connected or to == .err,
        .err => to == .disconnected,
    };
}

// ---------------------------------------------------------------------------
// Matrix action codes (matches Idris2 ABI: MatrixAction)
// ---------------------------------------------------------------------------

/// All 16 Matrix actions supported by this cartridge.
pub const MatrixAction = enum(c_int) {
    send_message = 0,
    send_event = 1,
    get_room = 2,
    list_rooms = 3,
    join_room = 4,
    leave_room = 5,
    invite_user = 6,
    kick_user = 7,
    set_room_state = 8,
    get_room_state = 9,
    sync = 10,
    search_messages = 11,
    upload_media = 12,
    get_profile = 13,
    set_display_name = 14,
    create_room = 15,
};

// ---------------------------------------------------------------------------
// Transaction ID generation
// ---------------------------------------------------------------------------

const TXN_PREFIX_LEN: usize = 32;

var txn_counter: u64 = 0;

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 4096;
const HOMESERVER_BUF_SIZE: usize = 512;

const SessionSlot = struct {
    active: bool = false,
    state: ConnState = .disconnected,
    token_buf: [BUF_SIZE]u8 = undefined,
    token_len: usize = 0,
    homeserver_buf: [HOMESERVER_BUF_SIZE]u8 = undefined,
    homeserver_len: usize = 0,
    room_count: u32 = 0,
    local_txn_counter: u64 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports: state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn matrix_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new session in Disconnected state. Returns slot index (>= 0) or -1.
pub export fn matrix_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .disconnected;
            slot.token_len = 0;
            slot.homeserver_len = 0;
            slot.room_count = 0;
            slot.local_txn_counter = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn matrix_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .disconnected)) return -2;

    slot.active = false;
    slot.state = .disconnected;
    slot.token_len = 0;
    slot.homeserver_len = 0;
    slot.room_count = 0;
    slot.local_txn_counter = 0;
    return 0;
}

/// Get the current state of a session. Returns state int or -1 if invalid slot.
pub export fn matrix_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Transition a session to Authenticating state.
pub export fn matrix_mcp_authenticate(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticating)) return -2;

    slot.state = .authenticating;
    return 0;
}

/// Transition a session to Connected state (auth succeeded).
pub export fn matrix_mcp_connect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .connected)) return -2;

    slot.state = .connected;
    return 0;
}

/// Transition a session to Syncing state.
pub export fn matrix_mcp_begin_sync(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .syncing)) return -2;

    slot.state = .syncing;
    return 0;
}

/// Transition a session from Syncing back to Connected.
pub export fn matrix_mcp_end_sync(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .connected)) return -2;

    slot.state = .connected;
    return 0;
}

/// Signal an error on a session.
pub export fn matrix_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    slot.state = .err;
    return 0;
}

/// Recover from error (transition to Disconnected).
pub export fn matrix_mcp_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .disconnected)) return -2;

    slot.state = .disconnected;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports: token, homeserver, actions, txn IDs
// ---------------------------------------------------------------------------

/// Validate a Matrix bearer token (basic structural check).
/// Must be non-empty and < 1000 chars with no control characters.
pub export fn matrix_mcp_validate_token(ptr: [*]const u8, len: usize) c_int {
    if (len == 0 or len >= 1000) return 0;
    for (ptr[0..len]) |byte| {
        if (byte < 0x20 or byte == 0x7F) return 0;
    }
    return 1;
}

/// Check if a Matrix action code is valid. Returns 1 if valid, 0 otherwise.
pub export fn matrix_mcp_is_valid_action(action: c_int) c_int {
    _ = std.meta.intToEnum(MatrixAction, action) catch return 0;
    return 1;
}

/// Get the total number of supported actions.
pub export fn matrix_mcp_action_count() c_int {
    return 16;
}

/// Generate the next transaction ID. Returns a monotonically increasing counter.
/// The caller should combine this with a prefix to form the full txnId string.
pub export fn matrix_mcp_next_txn_id() u64 {
    mutex.lock();
    defer mutex.unlock();
    txn_counter += 1;
    return txn_counter;
}

/// Reset all sessions and the transaction counter (test/debug use only).
pub export fn matrix_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
    txn_counter = 0;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "matrix-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "matrix_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "matrix_send_message"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "matrix_list_rooms"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "matrix_get_messages"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "matrix_join_room"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "matrix_leave_room"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "matrix_deauthenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "connection lifecycle" {
    matrix_mcp_reset();

    const slot = matrix_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be disconnected
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_session_state(slot));

    // Authenticate
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_authenticate(slot));
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_session_state(slot));

    // Connect
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_connect(slot));
    try std.testing.expectEqual(@as(c_int, 2), matrix_mcp_session_state(slot));

    // Sync and return
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_begin_sync(slot));
    try std.testing.expectEqual(@as(c_int, 3), matrix_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_end_sync(slot));
    try std.testing.expectEqual(@as(c_int, 2), matrix_mcp_session_state(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    matrix_mcp_reset();

    const slot = matrix_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Can't connect from disconnected
    try std.testing.expectEqual(@as(c_int, -2), matrix_mcp_connect(slot));

    // Can't sync from disconnected
    try std.testing.expectEqual(@as(c_int, -2), matrix_mcp_begin_sync(slot));

    // Authenticate, then can't sync
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_authenticate(slot));
    try std.testing.expectEqual(@as(c_int, -2), matrix_mcp_begin_sync(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(0, 1)); // disconnected -> authenticating
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(1, 2)); // authenticating -> connected
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(1, 4)); // authenticating -> error
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(2, 3)); // connected -> syncing
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(3, 2)); // syncing -> connected
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(2, 4)); // connected -> error
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(3, 4)); // syncing -> error
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(4, 0)); // error -> disconnected
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_can_transition(2, 0)); // connected -> disconnected

    // Invalid
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_can_transition(0, 2)); // disconnected -> connected
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_can_transition(0, 3)); // disconnected -> syncing
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_can_transition(4, 2)); // error -> connected
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_can_transition(99, 0));
}

test "token validation" {
    try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_validate_token("syt_abc_123".ptr, 11));
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_validate_token("".ptr, 0));
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_validate_token("abc\x00def".ptr, 7));
}

test "action validation" {
    var i: c_int = 0;
    while (i < 16) : (i += 1) {
        try std.testing.expectEqual(@as(c_int, 1), matrix_mcp_is_valid_action(i));
    }
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_is_valid_action(16));
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_is_valid_action(-1));
    try std.testing.expectEqual(@as(c_int, 16), matrix_mcp_action_count());
}

test "transaction ID generation" {
    matrix_mcp_reset();
    const id1 = matrix_mcp_next_txn_id();
    const id2 = matrix_mcp_next_txn_id();
    try std.testing.expect(id2 > id1);
}

test "slot exhaustion" {
    matrix_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = matrix_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), matrix_mcp_session_open());

    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_authenticate(slots[0]));
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_connect(slots[0]));
    try std.testing.expectEqual(@as(c_int, 0), matrix_mcp_session_close(slots[0]));
    const new_slot = matrix_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns matrix-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("matrix-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "matrix_authenticate",
        "matrix_send_message",
        "matrix_list_rooms",
        "matrix_get_messages",
        "matrix_join_room",
        "matrix_leave_room",
        "matrix_deauthenticate",
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
    const rc = boj_cartridge_invoke("matrix_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
