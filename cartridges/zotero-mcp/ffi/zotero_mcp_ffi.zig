// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// zotero_mcp_ffi.zig — C-ABI FFI implementation for zotero-mcp cartridge.
//
// Implements the state machine defined in ZoteroMcp.SafeRegistry (Idris2 ABI).
// State machine: Disconnected | Connected | RateLimited | Error
// Auth: Required API key — Zotero user libraries are always gated.
// REST API: https://api.zotero.org
// Actions: SearchItems, GetItem, ListCollections, GetCollectionItems,
//          ListTags, GetItemsByTag, GetAttachments, ExportCitation,
//          GetNotes, ListSavedSearches, GetGroupLibraries, GenerateBibliography
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

/// Zotero action identifiers matching Idris2 ZoteroAction encoding.
pub const ZoteroAction = enum(c_int) {
    search_items = 0,
    get_item = 1,
    list_collections = 2,
    get_collection_items = 3,
    list_tags = 4,
    get_items_by_tag = 5,
    get_attachments = 6,
    export_citation = 7,
    get_notes = 8,
    list_saved_searches = 9,
    get_group_libraries = 10,
    generate_bibliography = 11,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
/// Zotero always requires auth — no anonymous sessions.
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
    item_reads: u32 = 0,
    collection_queries: u32 = 0,
    tag_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn zotero_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Connect to Zotero (authenticated session). Returns slot index (>= 0) or error (< 0).
pub export fn zotero_mcp_connect(dummy: c_int) c_int {
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
            slot.item_reads = 0;
            slot.collection_queries = 0;
            slot.tag_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Disconnect from Zotero. Returns 0 on success.
pub export fn zotero_mcp_disconnect(slot_idx: c_int) c_int {
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
pub export fn zotero_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn zotero_mcp_throttle(slot_idx: c_int) c_int {
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
pub export fn zotero_mcp_unthrottle(slot_idx: c_int) c_int {
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
pub export fn zotero_mcp_signal_error(slot_idx: c_int) c_int {
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
pub export fn zotero_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(ZoteroAction, action) catch return -3;

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
        .search_items => sessions[idx].search_count += 1,
        .get_item, .get_attachments, .get_notes, .export_citation => sessions[idx].item_reads += 1,
        .list_collections, .get_collection_items, .get_group_libraries => sessions[idx].collection_queries += 1,
        .list_tags, .get_items_by_tag => sessions[idx].tag_queries += 1,
        else => {},
    }

    return 0;
}

/// Get API call count for a session.
pub export fn zotero_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get search query count.
pub export fn zotero_mcp_search_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.search_count);
}

/// Get item read count.
pub export fn zotero_mcp_item_read_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.item_reads);
}

/// Get collection query count.
pub export fn zotero_mcp_collection_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.collection_queries);
}

/// Get tag query count.
pub export fn zotero_mcp_tag_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.tag_queries);
}

/// Get total action count. Always returns 12.
pub export fn zotero_mcp_action_count() c_int {
    return 12;
}

/// Reset all sessions (test/debug use only).
pub export fn zotero_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "zotero-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "zotero_search_items"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_get_item"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_list_collections"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_get_collection_items"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_list_tags"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_get_items_by_tag"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_get_attachments"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_export_citation"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_get_notes"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_list_saved_searches"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_get_group_libraries"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "zotero_generate_bibliography"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "connected session lifecycle" {
    zotero_mcp_reset();

    const slot = zotero_mcp_connect(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_search_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_disconnect(slot));
}

test "requires connected state for actions" {
    zotero_mcp_reset();

    const slot = zotero_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), zotero_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_record_call(slot, 0));
}

test "error and recovery" {
    zotero_mcp_reset();

    const slot = zotero_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), zotero_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, -2), zotero_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_disconnect(slot));
}

test "category counting" {
    zotero_mcp_reset();

    const slot = zotero_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_record_call(slot, 0)); // SearchItems
    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_record_call(slot, 1)); // GetItem
    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_record_call(slot, 2)); // ListCollections
    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_record_call(slot, 4)); // ListTags

    try std.testing.expectEqual(@as(c_int, 4), zotero_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_search_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_item_read_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_collection_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_tag_query_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_can_transition(1, 3));
    try std.testing.expectEqual(@as(c_int, 1), zotero_mcp_can_transition(3, 0));
    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_can_transition(2, 3));
    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_can_transition(0, 2));
}

test "slot exhaustion" {
    zotero_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = zotero_mcp_connect(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), zotero_mcp_connect(0));

    try std.testing.expectEqual(@as(c_int, 0), zotero_mcp_disconnect(slots[0]));
    const new_slot = zotero_mcp_connect(0);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns zotero-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("zotero-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "zotero_search_items",
        "zotero_get_item",
        "zotero_list_collections",
        "zotero_get_collection_items",
        "zotero_list_tags",
        "zotero_get_items_by_tag",
        "zotero_get_attachments",
        "zotero_export_citation",
        "zotero_get_notes",
        "zotero_list_saved_searches",
        "zotero_get_group_libraries",
        "zotero_generate_bibliography",
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
    const rc = boj_cartridge_invoke("zotero_search_items", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
