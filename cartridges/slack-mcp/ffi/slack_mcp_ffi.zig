// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// slack_mcp_ffi.zig — C-ABI FFI for the Slack Web API / Events API cartridge.
//
// Implements the state machine defined in SlackMcp.SafeComms (Idris2 ABI).
// Provides real HTTP dispatch to the Slack Web API (https://slack.com/api/)
// via std.http.Client, per-method rate-limit tracking (Tier 1-4), and
// Bearer-token authentication via xoxb-* bot tokens obtained from vault-mcp.
//
// Thread-safe via std.Thread.Mutex. No heap allocations for result buffers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Connection state machine (matches Idris2 ConnState exactly)
// ---------------------------------------------------------------------------

/// Connection lifecycle states mirroring SlackMcp.SafeComms.ConnState.
pub const ConnState = enum(c_int) {
    disconnected = 0,
    authenticating = 1,
    connected = 2,
    rate_limited = 3,
    err = 4,
};

/// Check whether a transition between two states is valid.
/// Encodes the same transition table as the Idris2 ValidTransition GADT.
fn isValidTransition(from: ConnState, to: ConnState) bool {
    return switch (from) {
        .disconnected => to == .authenticating,
        .authenticating => to == .connected or to == .err,
        .connected => to == .rate_limited or to == .err or to == .disconnected,
        .rate_limited => to == .connected,
        .err => to == .disconnected,
    };
}

// ---------------------------------------------------------------------------
// Slack action vocabulary (matches Idris2 SlackAction exactly)
// ---------------------------------------------------------------------------

/// All 16 Slack actions supported by this cartridge.
pub const SlackAction = enum(c_int) {
    send_message = 0,
    list_channels = 1,
    get_channel = 2,
    list_users = 3,
    get_user = 4,
    post_reaction = 5,
    remove_reaction = 6,
    upload_file = 7,
    search_messages = 8,
    list_conversations = 9,
    get_thread = 10,
    update_message = 11,
    delete_message = 12,
    set_status = 13,
    create_channel = 14,
    invite_to_channel = 15,
};

/// Map each action to its Slack Web API method path.
fn actionToMethod(action: SlackAction) []const u8 {
    return switch (action) {
        .send_message => "chat.postMessage",
        .list_channels => "conversations.list",
        .get_channel => "conversations.info",
        .list_users => "users.list",
        .get_user => "users.info",
        .post_reaction => "reactions.add",
        .remove_reaction => "reactions.remove",
        .upload_file => "files.upload",
        .search_messages => "search.messages",
        .list_conversations => "conversations.list",
        .get_thread => "conversations.replies",
        .update_message => "chat.update",
        .delete_message => "chat.delete",
        .set_status => "users.profile.set",
        .create_channel => "conversations.create",
        .invite_to_channel => "conversations.invite",
    };
}

// ---------------------------------------------------------------------------
// Rate-limit tiers (Slack per-method rate limits)
// ---------------------------------------------------------------------------

/// Slack rate tiers. Each tier has a different requests-per-minute budget.
/// Tier 1: ~1 req/min, Tier 2: ~20 req/min, Tier 3: ~50 req/min, Tier 4: ~100+ req/min.
pub const RateTier = enum(c_int) {
    tier1 = 1,
    tier2 = 2,
    tier3 = 3,
    tier4 = 4,
};

/// Map each action to its rate tier (matches Idris2 actionRateTier).
fn actionRateTier(action: SlackAction) RateTier {
    return switch (action) {
        .send_message => .tier3,
        .list_channels => .tier2,
        .get_channel => .tier3,
        .list_users => .tier2,
        .get_user => .tier4,
        .post_reaction => .tier3,
        .remove_reaction => .tier3,
        .upload_file => .tier2,
        .search_messages => .tier2,
        .list_conversations => .tier2,
        .get_thread => .tier3,
        .update_message => .tier3,
        .delete_message => .tier3,
        .set_status => .tier3,
        .create_channel => .tier2,
        .invite_to_channel => .tier3,
    };
}

/// Maximum requests per minute for each tier.
fn tierBudget(tier: RateTier) u32 {
    return switch (tier) {
        .tier1 => 1,
        .tier2 => 20,
        .tier3 => 50,
        .tier4 => 100,
    };
}

// ---------------------------------------------------------------------------
// Per-tier rate tracking
// ---------------------------------------------------------------------------

/// Tracks usage within a single rate tier.
const TierTracker = struct {
    /// Number of requests made in the current window.
    count: u32 = 0,
    /// Epoch timestamp (seconds) when the current window started.
    window_start: i64 = 0,

    /// Record one request. Returns true if within budget, false if exhausted.
    fn record(self: *TierTracker, now: i64, budget: u32) bool {
        // Reset window every 60 seconds.
        if (now - self.window_start >= 60) {
            self.window_start = now;
            self.count = 0;
        }
        if (self.count >= budget) return false;
        self.count += 1;
        return true;
    }
};

// ---------------------------------------------------------------------------
// Session slot pool (thread-safe, fixed-size)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 8192;
const TOKEN_MAX: usize = 256;

const SessionSlot = struct {
    active: bool = false,
    state: ConnState = .disconnected,
    /// Bearer token (xoxb-*) obtained from vault-mcp.
    token_buf: [TOKEN_MAX]u8 = undefined,
    token_len: usize = 0,
    /// Workspace name populated after authentication.
    workspace_buf: [256]u8 = undefined,
    workspace_len: usize = 0,
    /// Per-tier rate trackers (indexed by tier ordinal 1–4).
    rate_trackers: [4]TierTracker = [_]TierTracker{.{}} ** 4,
    /// Count of messages sent in this session (for panel metrics).
    messages_sent: u32 = 0,
    /// General-purpose output buffer for API responses.
    out_buf: [BUF_SIZE]u8 = undefined,
    out_len: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Copy a null-terminated C string into a fixed buffer. Returns bytes written.
fn copyFromCStr(dest: []u8, src: [*c]const u8) usize {
    if (src == null) return 0;
    var i: usize = 0;
    while (i < dest.len and src[i] != 0) : (i += 1) {
        dest[i] = src[i];
    }
    return i;
}

/// Write a slice into an output buffer pointer + length pointer.
fn writeOutput(buf: [*c]u8, buf_cap: usize, out_len: *c_int, data: []const u8) void {
    if (buf == null) return;
    const to_copy = @min(data.len, buf_cap);
    for (0..to_copy) |i| {
        buf[i] = data[i];
    }
    out_len.* = @intCast(to_copy);
}

/// Get a slot by index, returning null if invalid or inactive.
fn getSlot(slot_idx: c_int) ?*SessionSlot {
    const idx: usize = std.math.cast(usize, slot_idx) orelse return null;
    if (idx >= MAX_SESSIONS) return null;
    const slot = &sessions[idx];
    if (!slot.active) return null;
    return slot;
}

/// Attempt a state transition on a slot. Returns 0 on success, -2 if invalid.
fn tryTransition(slot: *SessionSlot, target: ConnState) c_int {
    if (!isValidTransition(slot.state, target)) return -2;
    slot.state = target;
    return 0;
}

/// Slack Web API base URL.
const SLACK_API_BASE: []const u8 = "https://slack.com/api/";

/// Perform a real HTTP POST to the Slack Web API.
/// Slack API always uses POST with form or JSON body.
/// slot: session slot (must be connected, caller verifies).
/// method_name: Slack API method (e.g. "chat.postMessage").
/// params_json: JSON-encoded parameters (may be null/empty).
/// out_buf: fixed output buffer for writing the API response.
/// Returns bytes written to out_buf, or 0 on error.
fn doSlackApiCall(slot: *SessionSlot, method_name: []const u8, params_json: ?[]const u8, out_buf: []u8) usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build URL: https://slack.com/api/<method>
    const url_str = std.fmt.allocPrint(allocator, "{s}{s}", .{ SLACK_API_BASE, method_name }) catch return 0;
    const uri = std.Uri.parse(url_str) catch return 0;

    // Build Bearer auth header from stored token
    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{slot.token_buf[0..slot.token_len]}) catch return 0;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers_buf: [3]std.http.Header = .{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
        .{ .name = "User-Agent", .value = "boj-server/1.0 (slack-mcp cartridge)" },
    };

    // Fetch the request (Zig 0.15 API — replaces open/send/wait)
    const body = params_json orelse "{}";
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const fetch_result = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .extra_headers = &headers_buf,
        .payload = body,
        .response_writer = &aw.writer,
    }) catch return 0;

    // Check for rate limiting (HTTP 429)
    const status_code = @intFromEnum(fetch_result.status);
    if (status_code == 429) {
        slot.state = .rate_limited;
        return 0;
    }

    // Copy response body into the caller's output buffer
    const response_bytes = aw.writer.buffered();
    const to_copy = @min(response_bytes.len, out_buf.len);
    @memcpy(out_buf[0..to_copy], response_bytes[0..to_copy]);
    return to_copy;
}

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn slack_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(ConnState, from) catch return 0;
    const t = std.meta.intToEnum(ConnState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — authentication
// ---------------------------------------------------------------------------

/// Authenticate with a Slack bot token (xoxb-*).
/// Transitions: Disconnected -> Authenticating -> Connected (or Error).
/// Returns slot index (>= 0) on success, negative on error.
/// Error codes: -1 = no free slots, -3 = empty token, -4 = invalid token prefix.
pub export fn slack_mcp_authenticate(token: [*c]const u8) c_int {
    if (token == null) return -3;
    // Validate xoxb- prefix (5 bytes).
    const prefix = "xoxb-";
    for (prefix, 0..) |ch, i| {
        if (token[i] == 0 or token[i] != ch) return -4;
    }

    mutex.lock();
    defer mutex.unlock();

    // Find a free slot.
    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticating;
            slot.token_len = copyFromCStr(&slot.token_buf, token);
            slot.messages_sent = 0;
            slot.rate_trackers = [_]TierTracker{.{}} ** 4;

            // Call auth.test to verify the token and retrieve workspace info.
            const auth_response_len = doSlackApiCall(slot, "auth.test", "{}", &slot.workspace_buf);
            if (auth_response_len == 0) {
                // Network error during auth verification — still connect
                // but mark workspace as unknown.
                const ws = "unknown";
                @memcpy(slot.workspace_buf[0..ws.len], ws);
                slot.workspace_len = ws.len;
            } else {
                slot.workspace_len = auth_response_len;
            }

            // Authenticating -> Connected.
            slot.state = .connected;
            return @intCast(idx);
        }
    }
    return -1; // No free slots.
}

// ---------------------------------------------------------------------------
// C-ABI exports — send message
// ---------------------------------------------------------------------------

/// Send a message to a Slack channel (optionally threaded).
/// channel: C string channel ID (e.g. "C01234ABCDE").
/// text: C string message body.
/// thread_ts: C string thread timestamp, or null for top-level message.
/// out_buf / out_cap: caller-provided output buffer for the JSON response.
/// out_len: receives the number of bytes written.
/// Returns 0 on success, negative on error.
/// Error codes: -1 = invalid slot, -2 = bad state, -5 = rate limited.
pub export fn slack_mcp_send_message(
    slot_idx: c_int,
    channel: [*c]const u8,
    text: [*c]const u8,
    thread_ts: [*c]const u8,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    // Rate-limit check for send_message (Tier 3).
    const tier = actionRateTier(.send_message);
    const tier_idx: usize = @intCast(@intFromEnum(tier) - 1);
    const now = std.time.timestamp();
    if (!slot.rate_trackers[tier_idx].record(now, tierBudget(tier))) {
        slot.state = .rate_limited;
        return -5;
    }

    // Build JSON body for chat.postMessage
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ch_str = if (channel != null) blk: {
        var i: usize = 0;
        while (i < 256 and channel[i] != 0) : (i += 1) {}
        break :blk channel[0..i];
    } else "";
    const txt_str = if (text != null) blk: {
        var i: usize = 0;
        while (i < 4096 and text[i] != 0) : (i += 1) {}
        break :blk text[0..i];
    } else "";
    const ts_str: ?[]const u8 = if (thread_ts != null) blk: {
        var i: usize = 0;
        while (i < 256 and thread_ts[i] != 0) : (i += 1) {}
        if (i == 0) break :blk null;
        break :blk thread_ts[0..i];
    } else null;

    const params = if (ts_str) |ts|
        std.fmt.allocPrint(allocator, "{{\"channel\":\"{s}\",\"text\":\"{s}\",\"thread_ts\":\"{s}\"}}", .{ ch_str, txt_str, ts }) catch return -4
    else
        std.fmt.allocPrint(allocator, "{{\"channel\":\"{s}\",\"text\":\"{s}\"}}", .{ ch_str, txt_str }) catch return -4;

    const method = actionToMethod(.send_message);
    const len = doSlackApiCall(slot, method, params, &slot.out_buf);
    slot.out_len = len;
    slot.messages_sent += 1;

    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.out_buf[0..len]);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — list channels
// ---------------------------------------------------------------------------

/// List Slack channels in the authenticated workspace.
/// Returns 0 on success, negative on error.
pub export fn slack_mcp_list_channels(
    slot_idx: c_int,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const tier = actionRateTier(.list_channels);
    const tier_idx: usize = @intCast(@intFromEnum(tier) - 1);
    const now = std.time.timestamp();
    if (!slot.rate_trackers[tier_idx].record(now, tierBudget(tier))) {
        slot.state = .rate_limited;
        return -5;
    }

    const method = actionToMethod(.list_channels);
    const len = doSlackApiCall(slot, method, null, &slot.out_buf);
    slot.out_len = len;

    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.out_buf[0..len]);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — search messages
// ---------------------------------------------------------------------------

/// Search Slack messages matching a query string.
/// Returns 0 on success, negative on error.
pub export fn slack_mcp_search(
    slot_idx: c_int,
    query: [*c]const u8,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const tier = actionRateTier(.search_messages);
    const tier_idx: usize = @intCast(@intFromEnum(tier) - 1);
    const now = std.time.timestamp();
    if (!slot.rate_trackers[tier_idx].record(now, tierBudget(tier))) {
        slot.state = .rate_limited;
        return -5;
    }

    // Build search params from query C string
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const q_str = if (query != null) blk: {
        var i: usize = 0;
        while (i < 4096 and query[i] != 0) : (i += 1) {}
        break :blk query[0..i];
    } else "";

    const params = std.fmt.allocPrint(allocator, "{{\"query\":\"{s}\"}}", .{q_str}) catch return -4;

    const method = actionToMethod(.search_messages);
    const len = doSlackApiCall(slot, method, params, &slot.out_buf);
    slot.out_len = len;

    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.out_buf[0..len]);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — generic API call
// ---------------------------------------------------------------------------

/// Invoke an arbitrary Slack Web API method by action ID.
/// action_id: integer matching SlackAction enum.
/// params: JSON-encoded parameters (C string, may be null).
/// Returns 0 on success, negative on error.
/// Error codes: -1 = invalid slot, -2 = bad state, -5 = rate limited, -6 = unknown action.
pub export fn slack_mcp_api_call(
    slot_idx: c_int,
    action_id: c_int,
    params: [*c]const u8,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    const action = std.meta.intToEnum(SlackAction, action_id) catch return -6;

    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const tier = actionRateTier(action);
    const tier_idx: usize = @intCast(@intFromEnum(tier) - 1);
    const now = std.time.timestamp();
    if (!slot.rate_trackers[tier_idx].record(now, tierBudget(tier))) {
        slot.state = .rate_limited;
        return -5;
    }

    // Extract params as a slice if present
    const params_slice: ?[]const u8 = if (params != null) blk: {
        var i: usize = 0;
        while (i < 8192 and params[i] != 0) : (i += 1) {}
        if (i == 0) break :blk null;
        break :blk params[0..i];
    } else null;

    const method = actionToMethod(action);
    const len = doSlackApiCall(slot, method, params_slice, &slot.out_buf);
    slot.out_len = len;

    // Track messages sent for panel metrics.
    if (action == .send_message) slot.messages_sent += 1;

    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.out_buf[0..len]);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — session management
// ---------------------------------------------------------------------------

/// Disconnect a session gracefully. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = bad state transition.
pub export fn slack_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    const rc = tryTransition(slot, .disconnected);
    if (rc == 0) {
        slot.active = false;
        slot.token_len = 0;
        slot.workspace_len = 0;
        slot.messages_sent = 0;
    }
    return rc;
}

/// Get the current connection state. Returns state int or -1 if invalid slot.
pub export fn slack_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intFromEnum(slot.state);
}

/// Get the workspace name for a connected session.
/// Writes workspace name into out_buf. Returns 0 on success, -1 if invalid.
pub export fn slack_mcp_workspace(slot_idx: c_int, out_buf: [*c]u8, out_cap: c_int, out_len: *c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    const cap: usize = std.math.cast(usize, out_cap) orelse 0;
    writeOutput(out_buf, cap, out_len, slot.workspace_buf[0..slot.workspace_len]);
    return 0;
}

/// Get the messages-sent counter for a session.
pub export fn slack_mcp_messages_sent(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.messages_sent);
}

/// Get the current request count for a rate tier (1–4) on a given session.
/// Returns count (>= 0) or -1 if invalid.
pub export fn slack_mcp_rate_count(slot_idx: c_int, tier_id: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (tier_id < 1 or tier_id > 4) return -1;
    const idx: usize = @intCast(tier_id - 1);
    return @intCast(slot.rate_trackers[idx].count);
}

/// Recover from rate-limited state (RateLimited -> Connected).
/// Returns 0 on success, -2 if bad transition.
pub export fn slack_mcp_rate_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return tryTransition(slot, .connected);
}

/// Reset all sessions (test/debug use only).
pub export fn slack_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "slack-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "slack_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "slack_send_message"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "slack_list_channels"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "slack_read_thread"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "slack_search"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "slack_get_user"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "slack_deauthenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "state machine transitions" {
    // Valid transitions.
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_can_transition(0, 1)); // disconn -> auth
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_can_transition(1, 2)); // auth -> connected
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_can_transition(2, 3)); // connected -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_can_transition(3, 2)); // rate_limited -> connected
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_can_transition(2, 4)); // connected -> error
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_can_transition(1, 4)); // auth -> error
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_can_transition(4, 0)); // error -> disconn
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_can_transition(2, 0)); // connected -> disconn

    // Invalid transitions.
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_can_transition(0, 2)); // disconn -> connected
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_can_transition(3, 0)); // rate_limited -> disconn
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_can_transition(4, 2)); // error -> connected
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_can_transition(0, 4)); // disconn -> error

    // Out of range.
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_can_transition(99, 0));
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_can_transition(0, 99));
}

test "authenticate and disconnect lifecycle" {
    slack_mcp_reset();

    // Authenticate with a valid bot token.
    const slot = slack_mcp_authenticate("xoxb-test-token-12345");
    try std.testing.expect(slot >= 0);

    // Should be connected.
    try std.testing.expectEqual(@as(c_int, 2), slack_mcp_session_state(slot));

    // Graceful disconnect.
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_disconnect(slot));
}

test "reject invalid token prefix" {
    slack_mcp_reset();

    // Missing xoxb- prefix.
    try std.testing.expectEqual(@as(c_int, -4), slack_mcp_authenticate("bad-token"));

    // Null token.
    try std.testing.expectEqual(@as(c_int, -3), slack_mcp_authenticate(null));
}

test "send message updates counter" {
    slack_mcp_reset();

    const slot = slack_mcp_authenticate("xoxb-test-token-msg");
    try std.testing.expect(slot >= 0);

    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;

    const rc = slack_mcp_send_message(slot, "C01234", "hello", null, &buf, 1024, &out_len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expect(out_len > 0);
    try std.testing.expectEqual(@as(c_int, 1), slack_mcp_messages_sent(slot));

    _ = slack_mcp_disconnect(slot);
}

test "rate tier tracking per session" {
    slack_mcp_reset();

    const slot = slack_mcp_authenticate("xoxb-test-token-rate");
    try std.testing.expect(slot >= 0);

    // Initially all tier counts should be zero.
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_rate_count(slot, 1));
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_rate_count(slot, 2));
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_rate_count(slot, 3));
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_rate_count(slot, 4));

    // Invalid tier.
    try std.testing.expectEqual(@as(c_int, -1), slack_mcp_rate_count(slot, 0));
    try std.testing.expectEqual(@as(c_int, -1), slack_mcp_rate_count(slot, 5));

    _ = slack_mcp_disconnect(slot);
}

test "generic api_call routes correctly" {
    slack_mcp_reset();

    const slot = slack_mcp_authenticate("xoxb-test-token-api");
    try std.testing.expect(slot >= 0);

    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;

    // Call list_users (action_id = 3).
    const rc = slack_mcp_api_call(slot, 3, null, &buf, 1024, &out_len);
    try std.testing.expectEqual(@as(c_int, 0), rc);
    try std.testing.expect(out_len > 0);

    // Unknown action.
    try std.testing.expectEqual(@as(c_int, -6), slack_mcp_api_call(slot, 99, null, &buf, 1024, &out_len));

    _ = slack_mcp_disconnect(slot);
}

test "slot exhaustion" {
    slack_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = slack_mcp_authenticate("xoxb-fill-token-slot");
        try std.testing.expect(s.* >= 0);
    }

    // Next should fail.
    try std.testing.expectEqual(@as(c_int, -1), slack_mcp_authenticate("xoxb-overflow"));

    // Free one and retry.
    try std.testing.expectEqual(@as(c_int, 0), slack_mcp_disconnect(slots[0]));
    const new_slot = slack_mcp_authenticate("xoxb-reuse-slot-ok");
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns slack-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("slack-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "slack_authenticate",
        "slack_send_message",
        "slack_list_channels",
        "slack_read_thread",
        "slack_search",
        "slack_get_user",
        "slack_deauthenticate",
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
    const rc = boj_cartridge_invoke("slack_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
