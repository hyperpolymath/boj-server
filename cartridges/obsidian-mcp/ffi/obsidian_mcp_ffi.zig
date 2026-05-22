// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// obsidian_mcp_ffi.zig — C-ABI FFI implementation for obsidian-mcp cartridge.
//
// Implements the state machine defined in ObsidianMcp.SafeRegistry (Idris2 ABI).
// State machine: Disconnected | Connected | RateLimited | Error
// Auth: Required Bearer token — Obsidian REST API is local and always gated.
// REST API: https://127.0.0.1:27124
// Actions: SearchNotes, GetNote, ListNotes, GetBacklinks, GetOutgoingLinks,
//          ListTags, GetNotesByTag, GetFrontmatter, GetDailyNote, VaultStats,
//          DataviewQuery, ListTemplates
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session connection/lifecycle state.
/// 0 = Disconnected, 1 = Connected, 2 = RateLimited, 3 = Error.
pub const SessionState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    rate_limited = 2,
    err = 3,
};

/// Obsidian action identifiers matching Idris2 ObsidianAction encoding.
pub const ObsidianAction = enum(c_int) {
    search_notes = 0,
    get_note = 1,
    list_notes = 2,
    get_backlinks = 3,
    get_outgoing_links = 4,
    list_tags = 5,
    get_notes_by_tag = 6,
    get_frontmatter = 7,
    get_daily_note = 8,
    vault_stats = 9,
    dataview_query = 10,
    list_templates = 11,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
/// Obsidian always requires auth — no anonymous sessions.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .disconnected => to == .connected or to == .err,
        .connected => to == .disconnected or to == .rate_limited or to == .err,
        .rate_limited => to == .connected,
        .err => to == .connected or to == .disconnected,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .disconnected,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
    search_count: u32 = 0,
    note_reads: u32 = 0,
    link_queries: u32 = 0,
    tag_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn obsidian_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Connect to Obsidian (authenticated session). Returns slot index (>= 0) or error (< 0).
pub export fn obsidian_mcp_connect(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .connected;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.search_count = 0;
            slot.note_reads = 0;
            slot.link_queries = 0;
            slot.tag_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Disconnect from Obsidian. Returns 0 on success.
pub export fn obsidian_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

/// Get current state of a session. Returns state int or -1 if invalid.
pub export fn obsidian_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn obsidian_mcp_throttle(slot_idx: c_int) c_int {
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

/// Clear rate limiting. Returns 0 on success.
pub export fn obsidian_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .connected)) return -2;

    sessions[idx].state = .connected;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn obsidian_mcp_signal_error(slot_idx: c_int) c_int {
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
// C-ABI exports — action recording and metrics
// ---------------------------------------------------------------------------

/// Record an API call on a session. Returns 0 on success.
pub export fn obsidian_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(ObsidianAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .connected) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;

    switch (act) {
        .search_notes => sessions[idx].search_count += 1,
        .get_note, .list_notes, .get_frontmatter, .get_daily_note => sessions[idx].note_reads += 1,
        .get_backlinks, .get_outgoing_links => sessions[idx].link_queries += 1,
        .list_tags, .get_notes_by_tag => sessions[idx].tag_queries += 1,
        else => {},
    }

    return 0;
}

/// Get API call count for a session.
pub export fn obsidian_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get search query count.
pub export fn obsidian_mcp_search_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.search_count);
}

/// Get note read count.
pub export fn obsidian_mcp_note_read_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.note_reads);
}

/// Get link query count.
pub export fn obsidian_mcp_link_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.link_queries);
}

/// Get tag query count.
pub export fn obsidian_mcp_tag_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.tag_queries);
}

/// Get total action count. Always returns 12.
pub export fn obsidian_mcp_action_count() c_int {
    return 12;
}

/// Reset all sessions (test/debug use only).
pub export fn obsidian_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "obsidian-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "obsidian_search_notes"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_get_note"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_list_notes"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_get_backlinks"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_get_outgoing_links"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_list_tags"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_get_notes_by_tag"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_get_frontmatter"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_get_daily_note"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_vault_stats"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_dataview_query"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "obsidian_list_templates"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "connected session lifecycle" {
    obsidian_mcp_reset();

    const slot = obsidian_mcp_connect(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_search_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_disconnect(slot));
}

test "requires connected state for actions" {
    obsidian_mcp_reset();

    const slot = obsidian_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    // Throttle — cannot invoke while rate limited
    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), obsidian_mcp_record_call(slot, 0));

    // Unthrottle — can invoke again
    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_record_call(slot, 0));
}

test "error and recovery" {
    obsidian_mcp_reset();

    const slot = obsidian_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), obsidian_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), obsidian_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_disconnect(slot));
}

test "category counting" {
    obsidian_mcp_reset();

    const slot = obsidian_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_record_call(slot, 0)); // SearchNotes
    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_record_call(slot, 1)); // GetNote
    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_record_call(slot, 3)); // GetBacklinks
    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_record_call(slot, 5)); // ListTags

    try std.testing.expectEqual(@as(c_int, 4), obsidian_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_search_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_note_read_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_link_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_tag_query_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_can_transition(0, 1)); // Disconnected -> Connected
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_can_transition(1, 0)); // Connected -> Disconnected
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_can_transition(1, 2)); // Connected -> RateLimited
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_can_transition(2, 1)); // RateLimited -> Connected
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_can_transition(1, 3)); // Connected -> Error
    try std.testing.expectEqual(@as(c_int, 1), obsidian_mcp_can_transition(3, 0)); // Error -> Disconnected
    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_can_transition(2, 3)); // RateLimited -> Error (invalid)
    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_can_transition(0, 2)); // Disconnected -> RateLimited (invalid)
}

test "slot exhaustion" {
    obsidian_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = obsidian_mcp_connect(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), obsidian_mcp_connect(0));

    try std.testing.expectEqual(@as(c_int, 0), obsidian_mcp_disconnect(slots[0]));
    const new_slot = obsidian_mcp_connect(0);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns obsidian-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("obsidian-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "obsidian_search_notes",
        "obsidian_get_note",
        "obsidian_list_notes",
        "obsidian_get_backlinks",
        "obsidian_get_outgoing_links",
        "obsidian_list_tags",
        "obsidian_get_notes_by_tag",
        "obsidian_get_frontmatter",
        "obsidian_get_daily_note",
        "obsidian_vault_stats",
        "obsidian_dataview_query",
        "obsidian_list_templates",
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
    const rc = boj_cartridge_invoke("obsidian_search_notes", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
