// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Feedback-MCP Cartridge — Zig FFI bridge for feedback collection.
//
// Implements the feedback pipeline state machine from SafeFeedback.idr.
// Manages feedback channels, collects submissions, tracks sentiment,
// and enforces channel registration before feedback processing.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match FeedbackMcp.SafeFeedback encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const FeedbackState = enum(c_int) {
    inactive = 0,
    channel_registered = 1,
    collecting = 2,
    processing = 3,
    feedback_error = 4,
};

pub const FeedbackChannel = enum(c_int) {
    web_form = 1,
    api_endpoint = 2,
    email = 3,
    irc = 4,
    mastodon = 5,
    gitea = 6,
    custom = 99,
};

pub const Sentiment = enum(c_int) {
    negative = -1,
    neutral = 0,
    positive = 1,
    unclassified = -99,
};

// ═══════════════════════════════════════════════════════════════════════
// Feedback Pipeline State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_CHANNELS: usize = 8;
const MAX_FEEDBACK_PER_CHANNEL: usize = 64;

const FeedbackEntry = struct {
    active: bool,
    sentiment: Sentiment,
    timestamp: u64,
};

const ChannelSlot = struct {
    active: bool,
    channel: FeedbackChannel,
    state: FeedbackState,
    feedback_count: u32,
    positive_count: u32,
    negative_count: u32,
    neutral_count: u32,
};

var channels: [MAX_CHANNELS]ChannelSlot = [_]ChannelSlot{.{
    .active = false,
    .channel = .web_form,
    .state = .inactive,
    .feedback_count = 0,
    .positive_count = 0,
    .negative_count = 0,
    .neutral_count = 0,
}} ** MAX_CHANNELS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: FeedbackState, to: FeedbackState) bool {
    return switch (from) {
        .inactive => to == .channel_registered,
        .channel_registered => to == .collecting,
        .collecting => to == .processing or to == .inactive,
        .processing => to == .collecting or to == .feedback_error,
        .feedback_error => to == .collecting,
    };
}

/// Register a new feedback channel. Returns slot index or -1 on failure.
pub export fn fb_register(channel_type: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&channels, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.channel = @enumFromInt(channel_type);
            slot.state = .channel_registered;
            slot.feedback_count = 0;
            slot.positive_count = 0;
            slot.negative_count = 0;
            slot.neutral_count = 0;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Transition a channel to collecting state.
pub export fn fb_start_collecting(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CHANNELS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!channels[idx].active) return -1;
    if (!isValidTransition(channels[idx].state, .collecting)) return -2;
    channels[idx].state = .collecting;
    return 0;
}

/// Submit feedback to a channel (must be in collecting state).
pub export fn fb_submit(slot_idx: c_int, sentiment: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CHANNELS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!channels[idx].active) return -1;

    // Auto-transition from channel_registered to collecting if needed
    if (channels[idx].state == .channel_registered) {
        channels[idx].state = .collecting;
    }

    if (channels[idx].state != .collecting) return -2;

    channels[idx].feedback_count += 1;
    const s: Sentiment = @enumFromInt(sentiment);
    switch (s) {
        .positive => channels[idx].positive_count += 1,
        .negative => channels[idx].negative_count += 1,
        .neutral => channels[idx].neutral_count += 1,
        .unclassified => {},
    }
    return @intCast(channels[idx].feedback_count);
}

/// Get the state of a channel.
pub export fn fb_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CHANNELS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!channels[idx].active) return @intFromEnum(FeedbackState.inactive);
    return @intFromEnum(channels[idx].state);
}

/// Get the feedback count for a channel.
pub export fn fb_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CHANNELS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!channels[idx].active) return 0;
    return @intCast(channels[idx].feedback_count);
}

/// Get the positive feedback count for a channel.
pub export fn fb_positive_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CHANNELS) return 0;
    const idx: usize = @intCast(slot_idx);
    return @intCast(channels[idx].positive_count);
}

/// Get the negative feedback count for a channel.
pub export fn fb_negative_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CHANNELS) return 0;
    const idx: usize = @intCast(slot_idx);
    return @intCast(channels[idx].negative_count);
}

/// Get the neutral feedback count for a channel.
pub export fn fb_neutral_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CHANNELS) return 0;
    const idx: usize = @intCast(slot_idx);
    return @intCast(channels[idx].neutral_count);
}

/// Deregister a channel (must be in collecting state).
pub export fn fb_deregister(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_CHANNELS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!channels[idx].active) return -1;
    if (!isValidTransition(channels[idx].state, .inactive)) return -2;
    channels[idx].active = false;
    channels[idx].state = .inactive;
    return 0;
}

/// Validate a state transition (C-ABI export).
pub export fn fb_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: FeedbackState = @enumFromInt(from);
    const t: FeedbackState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all channels (for testing).
pub export fn fb_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&channels) |*slot| {
        slot.active = false;
        slot.state = .inactive;
        slot.feedback_count = 0;
        slot.positive_count = 0;
        slot.negative_count = 0;
        slot.neutral_count = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the feedback-mcp cartridge. Resets all channel slots.
pub export fn boj_cartridge_init() c_int {
    fb_reset();
    return 0;
}

/// Deinitialise the feedback-mcp cartridge. Resets all channel slots.
pub export fn boj_cartridge_deinit() void {
    fb_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "feedback-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 dispatch (boj_cartridge_invoke, 5th standard symbol)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

/// Dispatch the cartridge.json MCP tools. Grade D Alpha — each arm
/// returns a stub JSON body shaped to the tool's intended response.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "feedback_register_channel"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "feedback_start_collecting"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "feedback_submit"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "feedback_get_stats"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "register and deregister channel" {
    fb_reset();
    const slot = fb_register(@intFromEnum(FeedbackChannel.web_form));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(FeedbackState.channel_registered)), fb_state(slot));
    // Must start collecting before deregister
    try std.testing.expectEqual(@as(c_int, 0), fb_start_collecting(slot));
    try std.testing.expectEqual(@as(c_int, 0), fb_deregister(slot));
}

test "cannot submit to inactive channel" {
    fb_reset();
    // Slot 0 is not active — should fail
    try std.testing.expectEqual(@as(c_int, -1), fb_submit(0, @intFromEnum(Sentiment.positive)));
}

test "submit feedback and track sentiment" {
    fb_reset();
    const slot = fb_register(@intFromEnum(FeedbackChannel.api_endpoint));
    // Submit 3 positive, 2 negative, 1 neutral
    _ = fb_submit(slot, @intFromEnum(Sentiment.positive));
    _ = fb_submit(slot, @intFromEnum(Sentiment.positive));
    _ = fb_submit(slot, @intFromEnum(Sentiment.positive));
    _ = fb_submit(slot, @intFromEnum(Sentiment.negative));
    _ = fb_submit(slot, @intFromEnum(Sentiment.negative));
    _ = fb_submit(slot, @intFromEnum(Sentiment.neutral));
    try std.testing.expectEqual(@as(c_int, 6), fb_count(slot));
    try std.testing.expectEqual(@as(c_int, 3), fb_positive_count(slot));
    try std.testing.expectEqual(@as(c_int, 2), fb_negative_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), fb_neutral_count(slot));
}

test "cannot deregister while not collecting" {
    fb_reset();
    const slot = fb_register(@intFromEnum(FeedbackChannel.irc));
    // In channel_registered state, cannot deregister (must be collecting)
    try std.testing.expectEqual(@as(c_int, -2), fb_deregister(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), fb_can_transition(0, 1)); // inactive -> registered
    try std.testing.expectEqual(@as(c_int, 1), fb_can_transition(1, 2)); // registered -> collecting
    try std.testing.expectEqual(@as(c_int, 1), fb_can_transition(2, 3)); // collecting -> processing
    try std.testing.expectEqual(@as(c_int, 1), fb_can_transition(3, 2)); // processing -> collecting
    try std.testing.expectEqual(@as(c_int, 1), fb_can_transition(2, 0)); // collecting -> inactive
    // Invalid transitions — the key safety invariant
    try std.testing.expectEqual(@as(c_int, 0), fb_can_transition(0, 3)); // inactive -> processing (BLOCKED)
    try std.testing.expectEqual(@as(c_int, 0), fb_can_transition(0, 2)); // inactive -> collecting
    try std.testing.expectEqual(@as(c_int, 0), fb_can_transition(3, 0)); // processing -> inactive
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "feedback_register_channel",
        "feedback_start_collecting",
        "feedback_submit",
        "feedback_get_stats",
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
    const rc = boj_cartridge_invoke("feedback_register_channel", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
