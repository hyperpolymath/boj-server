// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// telegram_mcp_ffi.zig — C-ABI FFI implementation for telegram-mcp cartridge.
//
// Implements the connection state machine and Telegram action dispatch defined
// in the Idris2 ABI layer (TelegramMcp.SafeComms). Thread-safe via
// std.Thread.Mutex. Token-in-URL auth pattern for Telegram Bot API.
// Global rate limit: 30 messages per second.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI: TelegramMcp.SafeComms)
// ---------------------------------------------------------------------------

/// Connection state for Telegram bot sessions.
/// Disconnected(0) | Authenticating(1) | Connected(2) | RateLimited(3) | Error(4)
pub const ConnState = enum(c_int) {
    disconnected = 0,
    authenticating = 1,
    connected = 2,
    rate_limited = 3,
    err = 4,
};

/// Check whether a state transition is permitted by the state machine.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .disconnected => to == .authenticating,
        .authenticating => to == .connected or to == .err,
        .connected => to == .rate_limited or to == .err or to == .disconnected,
        .rate_limited => to == .connected or to == .err,
        .err => to == .disconnected,
    };
}

// ---------------------------------------------------------------------------
// Telegram action codes (matches Idris2 ABI: TelegramAction)
// ---------------------------------------------------------------------------

/// All 16 Telegram actions supported by this cartridge.
pub const TelegramAction = enum(c_int) {
    send_message = 0,
    edit_message = 1,
    delete_message = 2,
    get_updates = 3,
    get_chat = 4,
    list_chats = 5,
    send_photo = 6,
    send_document = 7,
    set_webhook = 8,
    delete_webhook = 9,
    get_webhook_info = 10,
    answer_callback = 11,
    send_sticker = 12,
    forward_message = 13,
    pin_message = 14,
    get_me = 15,
};

// ---------------------------------------------------------------------------
// Rate limit tracking
// ---------------------------------------------------------------------------

/// Telegram global rate limit: 30 messages per second.
const GLOBAL_RATE_LIMIT: u32 = 30;
/// Per-chat rate limit: 1 message per second.
const PER_CHAT_RATE_LIMIT: u32 = 1;
/// Group chat rate limit: 20 messages per minute.
const GROUP_RATE_LIMIT: u32 = 20;

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 4096;

const SessionSlot = struct {
    active: bool = false,
    state: ConnState = .disconnected,
    token_buf: [BUF_SIZE]u8 = undefined,
    token_len: usize = 0,
    bot_username_buf: [256]u8 = undefined,
    bot_username_len: usize = 0,
    message_count: u64 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports: state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn telegram_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new session in Disconnected state. Returns slot index (>= 0) or -1.
pub export fn telegram_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .disconnected;
            slot.token_len = 0;
            slot.bot_username_len = 0;
            slot.message_count = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn telegram_mcp_session_close(slot_idx: c_int) c_int {
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
    slot.bot_username_len = 0;
    slot.message_count = 0;
    return 0;
}

/// Get the current state of a session. Returns state int or -1 if invalid slot.
pub export fn telegram_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Transition a session to Authenticating state.
pub export fn telegram_mcp_authenticate(slot_idx: c_int) c_int {
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
pub export fn telegram_mcp_connect(slot_idx: c_int) c_int {
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

/// Transition a session to RateLimited state.
pub export fn telegram_mcp_rate_limit(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .rate_limited)) return -2;

    slot.state = .rate_limited;
    return 0;
}

/// Signal an error on a session.
pub export fn telegram_mcp_signal_error(slot_idx: c_int) c_int {
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
pub export fn telegram_mcp_recover(slot_idx: c_int) c_int {
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
// C-ABI exports: token validation and actions
// ---------------------------------------------------------------------------

/// Validate a Telegram bot token (basic structural check).
/// Telegram tokens look like: 123456789:ABCDefGHIJKlmNOpqrSTUvwxYZ
/// Must contain a colon, be > 10 chars, and < 200 chars.
pub export fn telegram_mcp_validate_token(ptr: [*]const u8, len: usize) c_int {
    if (len <= 10 or len >= 200) return 0;
    var has_colon = false;
    for (ptr[0..len]) |byte| {
        if (byte < 0x20 or byte == 0x7F) return 0;
        if (byte == ':') has_colon = true;
    }
    return if (has_colon) 1 else 0;
}

/// Check if a Telegram action code is valid. Returns 1 if valid, 0 otherwise.
pub export fn telegram_mcp_is_valid_action(action: c_int) c_int {
    _ = std.meta.intToEnum(TelegramAction, action) catch return 0;
    return 1;
}

/// Get the total number of supported actions.
pub export fn telegram_mcp_action_count() c_int {
    return 16;
}

/// Get the global rate limit (messages per second).
pub export fn telegram_mcp_global_rate_limit() c_int {
    return @intCast(GLOBAL_RATE_LIMIT);
}

/// Reset all sessions (test/debug use only).
pub export fn telegram_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "telegram-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "telegram_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "telegram_send_message"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "telegram_get_updates"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "telegram_get_chat"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "telegram_send_photo"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "telegram_deauthenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "connection lifecycle" {
    telegram_mcp_reset();

    const slot = telegram_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be disconnected
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_session_state(slot));

    // Authenticate
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_authenticate(slot));
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_session_state(slot));

    // Connect
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_connect(slot));
    try std.testing.expectEqual(@as(c_int, 2), telegram_mcp_session_state(slot));

    // Rate limit and recover
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_rate_limit(slot));
    try std.testing.expectEqual(@as(c_int, 3), telegram_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_connect(slot));
    try std.testing.expectEqual(@as(c_int, 2), telegram_mcp_session_state(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    telegram_mcp_reset();

    const slot = telegram_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Can't connect from disconnected
    try std.testing.expectEqual(@as(c_int, -2), telegram_mcp_connect(slot));

    // Can't rate-limit from disconnected
    try std.testing.expectEqual(@as(c_int, -2), telegram_mcp_rate_limit(slot));

    // Authenticate, then can't re-authenticate
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_authenticate(slot));
    try std.testing.expectEqual(@as(c_int, -2), telegram_mcp_authenticate(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_can_transition(1, 4));
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_can_transition(2, 3));
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_can_transition(3, 2));
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_can_transition(2, 4));
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_can_transition(4, 0));
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_can_transition(2, 0));

    // Invalid
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_can_transition(0, 3));
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_can_transition(4, 2));
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_can_transition(99, 0));
}

test "token validation" {
    // Valid token (contains colon, > 10 chars)
    try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_validate_token("123456789:ABCdef".ptr, 16));

    // Too short
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_validate_token("12:ab".ptr, 5));

    // No colon
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_validate_token("12345678901234".ptr, 14));

    // Empty
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_validate_token("".ptr, 0));
}

test "action validation" {
    var i: c_int = 0;
    while (i < 16) : (i += 1) {
        try std.testing.expectEqual(@as(c_int, 1), telegram_mcp_is_valid_action(i));
    }
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_is_valid_action(16));
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_is_valid_action(-1));
    try std.testing.expectEqual(@as(c_int, 16), telegram_mcp_action_count());
    try std.testing.expectEqual(@as(c_int, 30), telegram_mcp_global_rate_limit());
}

test "slot exhaustion" {
    telegram_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = telegram_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), telegram_mcp_session_open());

    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_authenticate(slots[0]));
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_connect(slots[0]));
    try std.testing.expectEqual(@as(c_int, 0), telegram_mcp_session_close(slots[0]));
    const new_slot = telegram_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns telegram-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("telegram-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "telegram_authenticate",
        "telegram_send_message",
        "telegram_get_updates",
        "telegram_get_chat",
        "telegram_send_photo",
        "telegram_deauthenticate",
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
    const rc = boj_cartridge_invoke("telegram_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
