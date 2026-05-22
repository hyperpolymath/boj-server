// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// CodeSeeker-MCP Cartridge — Zig FFI bridge for code intelligence operations.
//
// Implements the index state machine from CodeseekerMcp.SearchGraph.idr.
// Ensures:
//   - No search or graph traversal before a codebase is indexed
//   - No concurrent index builds on the same path
//   - Clean session lifecycle with error recovery

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match CodeseekerMcp.SearchGraph encodings)
// ═══════════════════════════════════════════════════════════════════════

/// Lifecycle states for a CodeSeeker index session.
pub const IndexState = enum(c_int) {
    uninitialised = 0,
    indexing = 1,
    ready = 2,
    querying = 3,
    index_error = 4,
};

/// Search strategy modes.
pub const SearchMode = enum(c_int) {
    vector = 1,
    text = 2,
    path = 3,
    hybrid = 4,
};

/// Knowledge graph edge types.
pub const GraphRelation = enum(c_int) {
    imports = 1,
    calls = 2,
    extends = 3,
    implements = 4,
    uses = 5,
};

// ═══════════════════════════════════════════════════════════════════════
// Index Session Pool
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 16;
const MAX_PATH_LEN: usize = 4096;

const IndexSlot = struct {
    active: bool,
    state: IndexState,
    /// djb2 hash of the codebase path — used to detect duplicate sessions.
    path_hash: u64,
    file_count: u32,
};

var sessions: [MAX_SESSIONS]IndexSlot = [_]IndexSlot{.{
    .active = false,
    .state = .uninitialised,
    .path_hash = 0,
    .file_count = 0,
}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// djb2 hash for a null-terminated C string.
fn hashPath(path: [*:0]const u8) u64 {
    var h: u64 = 5381;
    var i: usize = 0;
    while (path[i] != 0) : (i += 1) {
        h = ((h << 5) +% h) +% @as(u64, path[i]);
    }
    return h;
}

/// Validate a state transition (matches Idris2 canIndexTransition).
fn isValidTransition(from: IndexState, to: IndexState) bool {
    return switch (from) {
        .uninitialised => to == .indexing,
        .indexing => to == .ready or to == .index_error,
        .ready => to == .querying,
        .querying => to == .ready or to == .index_error,
        .index_error => to == .uninitialised,
    };
}

// ═══════════════════════════════════════════════════════════════════════
// Session Lifecycle
// ═══════════════════════════════════════════════════════════════════════

/// Open a new index session for the given codebase path.
/// Returns slot index, or -1 if no slots available, or -2 if path already
/// has an active indexing session (prevents duplicate index builds).
pub export fn codeseeker_open_session(path: [*:0]const u8) c_int {
    mutex.lock();
    defer mutex.unlock();
    const ph = hashPath(path);
    // Check for duplicate active indexing session on same path.
    for (&sessions) |*slot| {
        if (slot.active and slot.state == .indexing and slot.path_hash == ph) {
            return -2; // Already indexing this path
        }
    }
    // Find an empty slot.
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .uninitialised;
            slot.path_hash = ph;
            slot.file_count = 0;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Close an index session and free its slot.
pub export fn codeseeker_close_session(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    sessions[idx].active = false;
    sessions[idx].state = .uninitialised;
    sessions[idx].path_hash = 0;
    sessions[idx].file_count = 0;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// State Transitions
// ═══════════════════════════════════════════════════════════════════════

/// Begin indexing (transition Uninitialised -> Indexing).
pub export fn codeseeker_begin_index(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .indexing)) return -2;
    sessions[idx].state = .indexing;
    return 0;
}

/// Mark indexing complete (transition Indexing -> Ready), recording file count.
pub export fn codeseeker_finish_index(slot_idx: c_int, file_count: c_uint) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .ready)) return -2;
    sessions[idx].state = .ready;
    sessions[idx].file_count = file_count;
    return 0;
}

/// Begin a query (transition Ready -> Querying).
pub export fn codeseeker_begin_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .querying)) return -2;
    sessions[idx].state = .querying;
    return 0;
}

/// Finish a query (transition Querying -> Ready).
pub export fn codeseeker_finish_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .ready)) return -2;
    sessions[idx].state = .ready;
    return 0;
}

/// Signal an error on a session (transition Indexing/Querying -> IndexError).
pub export fn codeseeker_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .index_error)) return -2;
    sessions[idx].state = .index_error;
    return 0;
}

/// Reset an errored session (transition IndexError -> Uninitialised).
pub export fn codeseeker_reset_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .uninitialised)) return -2;
    sessions[idx].state = .uninitialised;
    sessions[idx].file_count = 0;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Query Helpers
// ═══════════════════════════════════════════════════════════════════════

/// Get current state of a session.
pub export fn codeseeker_get_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(IndexState.uninitialised);
    return @intFromEnum(sessions[idx].state);
}

/// Get the indexed file count for a session (0 if not Ready).
pub export fn codeseeker_get_file_count(slot_idx: c_int) c_uint {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return 0;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return 0;
    return sessions[idx].file_count;
}

/// Validate a state transition (C-ABI export, matches Idris2).
pub export fn codeseeker_can_transition(from: c_int, to: c_int) c_int {
    const f: IndexState = @enumFromInt(from);
    const t: IndexState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sessions (for testing).
pub export fn codeseeker_reset_all() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        slot.active = false;
        slot.state = .uninitialised;
        slot.path_hash = 0;
        slot.file_count = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the codeseeker-mcp cartridge.
pub export fn boj_cartridge_init() c_int {
    codeseeker_reset_all();
    return 0;
}

/// Deinitialise the codeseeker-mcp cartridge.
pub export fn boj_cartridge_deinit() void {
    codeseeker_reset_all();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "codeseeker-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "codeseeker_open"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "codeseeker_close"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "codeseeker_index"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "codeseeker_query"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "codeseeker_state"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "open and close session" {
    codeseeker_reset_all();
    const slot = codeseeker_open_session("/home/hyper/repos/myproject");
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IndexState.uninitialised)), codeseeker_get_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_close_session(slot));
}

test "full index lifecycle" {
    codeseeker_reset_all();
    const slot = codeseeker_open_session("/repos/boj-server");
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_begin_index(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IndexState.indexing)), codeseeker_get_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_finish_index(slot, 512));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IndexState.ready)), codeseeker_get_state(slot));
    try std.testing.expectEqual(@as(c_uint, 512), codeseeker_get_file_count(slot));
    _ = codeseeker_close_session(slot);
}

test "query lifecycle" {
    codeseeker_reset_all();
    const slot = codeseeker_open_session("/repos/test");
    _ = codeseeker_begin_index(slot);
    _ = codeseeker_finish_index(slot, 100);
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IndexState.querying)), codeseeker_get_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_finish_query(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IndexState.ready)), codeseeker_get_state(slot));
    _ = codeseeker_close_session(slot);
}

test "cannot query before indexing" {
    codeseeker_reset_all();
    const slot = codeseeker_open_session("/repos/uninitialised");
    // Uninitialised -> Querying is invalid
    try std.testing.expectEqual(@as(c_int, -2), codeseeker_begin_query(slot));
    _ = codeseeker_close_session(slot);
}

test "cannot index while already indexing" {
    codeseeker_reset_all();
    const slot = codeseeker_open_session("/repos/being-indexed");
    _ = codeseeker_begin_index(slot);
    // Indexing -> Indexing is invalid
    try std.testing.expectEqual(@as(c_int, -2), codeseeker_begin_index(slot));
    _ = codeseeker_close_session(slot);
}

test "duplicate path rejection during indexing" {
    codeseeker_reset_all();
    const path = "/repos/shared-codebase";
    const slot1 = codeseeker_open_session(path);
    _ = codeseeker_begin_index(slot1);
    // Opening another session for the same path while indexing is blocked
    const slot2 = codeseeker_open_session(path);
    try std.testing.expectEqual(@as(c_int, -2), slot2);
    _ = codeseeker_close_session(slot1);
}

test "error recovery" {
    codeseeker_reset_all();
    const slot = codeseeker_open_session("/repos/failing");
    _ = codeseeker_begin_index(slot);
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IndexState.index_error)), codeseeker_get_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_reset_error(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(IndexState.uninitialised)), codeseeker_get_state(slot));
    _ = codeseeker_close_session(slot);
}

test "transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), codeseeker_can_transition(0, 1)); // uninit -> indexing
    try std.testing.expectEqual(@as(c_int, 1), codeseeker_can_transition(1, 2)); // indexing -> ready
    try std.testing.expectEqual(@as(c_int, 1), codeseeker_can_transition(1, 4)); // indexing -> error
    try std.testing.expectEqual(@as(c_int, 1), codeseeker_can_transition(2, 3)); // ready -> querying
    try std.testing.expectEqual(@as(c_int, 1), codeseeker_can_transition(3, 2)); // querying -> ready
    try std.testing.expectEqual(@as(c_int, 1), codeseeker_can_transition(3, 4)); // querying -> error
    try std.testing.expectEqual(@as(c_int, 1), codeseeker_can_transition(4, 0)); // error -> uninit
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_can_transition(0, 2)); // uninit -> ready
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_can_transition(0, 3)); // uninit -> querying
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_can_transition(2, 0)); // ready -> uninit
    try std.testing.expectEqual(@as(c_int, 0), codeseeker_can_transition(3, 1)); // querying -> indexing
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "codeseeker_open",
        "codeseeker_close",
        "codeseeker_index",
        "codeseeker_query",
        "codeseeker_state",
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
    const rc = boj_cartridge_invoke("codeseeker_open", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
