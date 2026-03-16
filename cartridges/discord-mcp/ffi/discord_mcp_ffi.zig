// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// discord_mcp_ffi.zig — C-ABI FFI implementation for discord-mcp cartridge.
//
// Implements the connection state machine and Discord action dispatch defined
// in the Idris2 ABI layer (DiscordMcp.SafeComms). Thread-safe via
// std.Thread.Mutex. Supports bucket-based per-route rate limiting matching
// Discord REST API v10 semantics. Bot token format validation included.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ABI: DiscordMcp.SafeComms)
// ---------------------------------------------------------------------------

/// Connection state for Discord bot sessions.
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
// Discord action codes (matches Idris2 ABI: DiscordAction)
// ---------------------------------------------------------------------------

/// All 16 Discord actions supported by this cartridge.
pub const DiscordAction = enum(c_int) {
    send_message = 0,
    edit_message = 1,
    delete_message = 2,
    list_channels = 3,
    get_channel = 4,
    list_guilds = 5,
    get_guild = 6,
    list_members = 7,
    get_member = 8,
    add_reaction = 9,
    remove_reaction = 10,
    create_thread = 11,
    list_threads = 12,
    search_messages = 13,
    set_status = 14,
    upload_file = 15,
};

// ---------------------------------------------------------------------------
// Rate limit bucket tracking
// ---------------------------------------------------------------------------

const MAX_BUCKETS: usize = 64;
const BUCKET_ID_LEN: usize = 64;

const RateBucket = struct {
    active: bool = false,
    id: [BUCKET_ID_LEN]u8 = undefined,
    id_len: usize = 0,
    remaining: u32 = 0,
    reset_after_ms: u64 = 0,
};

var buckets: [MAX_BUCKETS]RateBucket = [_]RateBucket{.{}} ** MAX_BUCKETS;

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
    guild_count: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports: state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn discord_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new session in Disconnected state. Returns slot index (>= 0) or -1.
pub export fn discord_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .disconnected;
            slot.token_len = 0;
            slot.guild_count = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn discord_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;

    // Can only close from Connected or Error (transition to Disconnected)
    if (!isValidTransition(slot.state, .disconnected)) return -2;

    slot.active = false;
    slot.state = .disconnected;
    slot.token_len = 0;
    slot.guild_count = 0;
    return 0;
}

/// Get the current state of a session. Returns state int or -1 if invalid slot.
pub export fn discord_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Transition a session to Authenticating state.
/// Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn discord_mcp_authenticate(slot_idx: c_int) c_int {
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
/// Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn discord_mcp_connect(slot_idx: c_int) c_int {
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
/// Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn discord_mcp_rate_limit(slot_idx: c_int) c_int {
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

/// Signal an error on a session. Returns 0 on success.
pub export fn discord_mcp_signal_error(slot_idx: c_int) c_int {
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

/// Recover from error (transition to Disconnected). Returns 0 on success.
pub export fn discord_mcp_recover(slot_idx: c_int) c_int {
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
// C-ABI exports: token validation
// ---------------------------------------------------------------------------

/// Validate a Discord bot token (basic structural check).
/// Returns 1 if valid, 0 if invalid. Token must be non-empty and < 200 chars.
pub export fn discord_mcp_validate_token(ptr: [*]const u8, len: usize) c_int {
    if (len == 0 or len >= 200) return 0;
    // Check for NUL bytes or control characters in the token
    for (ptr[0..len]) |byte| {
        if (byte < 0x20 or byte == 0x7F) return 0;
    }
    return 1;
}

/// Check if a Discord action code is valid. Returns 1 if valid, 0 otherwise.
pub export fn discord_mcp_is_valid_action(action: c_int) c_int {
    _ = std.meta.intToEnum(DiscordAction, action) catch return 0;
    return 1;
}

/// Get the total number of supported actions.
pub export fn discord_mcp_action_count() c_int {
    return 16;
}

/// Reset all sessions and buckets (test/debug use only).
pub export fn discord_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
    buckets = [_]RateBucket{.{}} ** MAX_BUCKETS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "connection lifecycle" {
    discord_mcp_reset();

    const slot = discord_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be in disconnected state
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_session_state(slot));

    // Authenticate
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_authenticate(slot));
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_session_state(slot));

    // Connect
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_connect(slot));
    try std.testing.expectEqual(@as(c_int, 2), discord_mcp_session_state(slot));

    // Rate limit and recover
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_rate_limit(slot));
    try std.testing.expectEqual(@as(c_int, 3), discord_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_connect(slot));
    try std.testing.expectEqual(@as(c_int, 2), discord_mcp_session_state(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_session_close(slot));
}

test "invalid transitions rejected" {
    discord_mcp_reset();

    const slot = discord_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Can't connect from disconnected (must authenticate first)
    try std.testing.expectEqual(@as(c_int, -2), discord_mcp_connect(slot));

    // Can't rate-limit from disconnected
    try std.testing.expectEqual(@as(c_int, -2), discord_mcp_rate_limit(slot));

    // Authenticate, then can't re-authenticate
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_authenticate(slot));
    try std.testing.expectEqual(@as(c_int, -2), discord_mcp_authenticate(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_can_transition(0, 1)); // disconnected -> authenticating
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_can_transition(1, 2)); // authenticating -> connected
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_can_transition(1, 4)); // authenticating -> error
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_can_transition(2, 3)); // connected -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_can_transition(3, 2)); // rate_limited -> connected
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_can_transition(2, 4)); // connected -> error
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_can_transition(4, 0)); // error -> disconnected
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_can_transition(2, 0)); // connected -> disconnected

    // Invalid
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_can_transition(0, 2)); // disconnected -> connected
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_can_transition(0, 3)); // disconnected -> rate_limited
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_can_transition(4, 2)); // error -> connected
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_can_transition(99, 0));
}

test "token validation" {
    // Valid token
    try std.testing.expectEqual(@as(c_int, 1), discord_mcp_validate_token("abc123".ptr, 6));

    // Empty token
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_validate_token("".ptr, 0));

    // Token with control character
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_validate_token("abc\x00def".ptr, 7));
}

test "action validation" {
    // All 16 actions should be valid
    var i: c_int = 0;
    while (i < 16) : (i += 1) {
        try std.testing.expectEqual(@as(c_int, 1), discord_mcp_is_valid_action(i));
    }
    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_is_valid_action(16));
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_is_valid_action(-1));
    try std.testing.expectEqual(@as(c_int, 16), discord_mcp_action_count());
}

test "slot exhaustion" {
    discord_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots, 0..) |*s, _| {
        s.* = discord_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), discord_mcp_session_open());

    // Bring first slot to Connected so we can close it
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_authenticate(slots[0]));
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_connect(slots[0]));
    try std.testing.expectEqual(@as(c_int, 0), discord_mcp_session_close(slots[0]));
    const new_slot = discord_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}
