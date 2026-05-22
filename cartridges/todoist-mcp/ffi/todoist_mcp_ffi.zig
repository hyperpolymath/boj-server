// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// todoist_mcp_ffi.zig — C-ABI FFI implementation for todoist-mcp cartridge.
//
// Implements the state machine defined in TodoistMcp.SafeRegistry (Idris2 ABI).
// State machine: Disconnected | Connected | RateLimited | Error
// Auth: Required Bearer token — Todoist API is always gated.
// REST API: https://api.todoist.com/rest/v2
// Actions: GetTasks, GetTask, CreateTask, CompleteTask, ListProjects,
//          GetProject, ListLabels, GetComments, ListSections, GetCompletedTasks
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

/// Todoist action identifiers matching Idris2 TodoistAction encoding.
pub const TodoistAction = enum(c_int) {
    get_tasks = 0,
    get_task = 1,
    create_task = 2,
    complete_task = 3,
    list_projects = 4,
    get_project = 5,
    list_labels = 6,
    get_comments = 7,
    list_sections = 8,
    get_completed_tasks = 9,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
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
    task_reads: u32 = 0,
    task_writes: u32 = 0,
    project_queries: u32 = 0,
    meta_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn todoist_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Connect to Todoist (authenticated session). Returns slot index (>= 0) or error (< 0).
pub export fn todoist_mcp_connect(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .connected;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.task_reads = 0;
            slot.task_writes = 0;
            slot.project_queries = 0;
            slot.meta_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Disconnect from Todoist. Returns 0 on success.
pub export fn todoist_mcp_disconnect(slot_idx: c_int) c_int {
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
pub export fn todoist_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn todoist_mcp_throttle(slot_idx: c_int) c_int {
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
pub export fn todoist_mcp_unthrottle(slot_idx: c_int) c_int {
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
pub export fn todoist_mcp_signal_error(slot_idx: c_int) c_int {
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
pub export fn todoist_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(TodoistAction, action) catch return -3;

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
        .get_tasks, .get_task, .get_completed_tasks => sessions[idx].task_reads += 1,
        .create_task, .complete_task => sessions[idx].task_writes += 1,
        .list_projects, .get_project, .list_sections => sessions[idx].project_queries += 1,
        .list_labels, .get_comments => sessions[idx].meta_queries += 1,
    }

    return 0;
}

/// Get API call count for a session.
pub export fn todoist_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get task read count.
pub export fn todoist_mcp_task_read_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.task_reads);
}

/// Get task write count.
pub export fn todoist_mcp_task_write_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.task_writes);
}

/// Get project query count.
pub export fn todoist_mcp_project_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.project_queries);
}

/// Get meta query count.
pub export fn todoist_mcp_meta_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.meta_queries);
}

/// Get total action count. Always returns 10.
pub export fn todoist_mcp_action_count() c_int {
    return 10;
}

/// Reset all sessions (test/debug use only).
pub export fn todoist_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "todoist-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "todoist_get_tasks"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_get_task"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_create_task"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_complete_task"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_list_projects"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_get_project"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_list_labels"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_get_comments"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_list_sections"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "todoist_get_completed_tasks"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "connected session lifecycle" {
    todoist_mcp_reset();

    const slot = todoist_mcp_connect(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_task_read_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_disconnect(slot));
}

test "requires connected state for actions" {
    todoist_mcp_reset();

    const slot = todoist_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), todoist_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_record_call(slot, 0));
}

test "category counting" {
    todoist_mcp_reset();

    const slot = todoist_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_record_call(slot, 0)); // GetTasks
    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_record_call(slot, 2)); // CreateTask
    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_record_call(slot, 4)); // ListProjects
    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_record_call(slot, 6)); // ListLabels

    try std.testing.expectEqual(@as(c_int, 4), todoist_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_task_read_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_task_write_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_project_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_meta_query_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_can_transition(1, 3));
    try std.testing.expectEqual(@as(c_int, 1), todoist_mcp_can_transition(3, 0));
    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_can_transition(2, 3));
    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_can_transition(0, 2));
}

test "slot exhaustion" {
    todoist_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = todoist_mcp_connect(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), todoist_mcp_connect(0));

    try std.testing.expectEqual(@as(c_int, 0), todoist_mcp_disconnect(slots[0]));
    const new_slot = todoist_mcp_connect(0);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns todoist-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("todoist-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "todoist_get_tasks",
        "todoist_get_task",
        "todoist_create_task",
        "todoist_complete_task",
        "todoist_list_projects",
        "todoist_get_project",
        "todoist_list_labels",
        "todoist_get_comments",
        "todoist_list_sections",
        "todoist_get_completed_tasks",
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
    const rc = boj_cartridge_invoke("todoist_get_tasks", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
