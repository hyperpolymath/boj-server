// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// google_sheets_mcp_ffi.zig — C-ABI FFI implementation for google-sheets-mcp cartridge.
//
// Implements the state machine defined in GoogleSheetsMcp.SafeRegistry (Idris2 ABI).
// State machine: Disconnected | Connected | RateLimited | Error
// Auth: Required OAuth2 Bearer token — Google Sheets API is always gated.
// REST API: https://sheets.googleapis.com/v4
// Actions: GetSpreadsheet, ReadRange, ListSheets, GetNamedRanges,
//          WriteRange, AppendRows, CreateSheet, BatchRead,
//          GetConditionalFormats, GetPivotTables
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

pub const SessionState = enum(c_int) {
    disconnected = 0,
    connected = 1,
    rate_limited = 2,
    err = 3,
};

pub const GoogleSheetsAction = enum(c_int) {
    get_spreadsheet = 0,
    read_range = 1,
    list_sheets = 2,
    get_named_ranges = 3,
    write_range = 4,
    append_rows = 5,
    create_sheet = 6,
    batch_read = 7,
    get_conditional_formats = 8,
    get_pivot_tables = 9,
};

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
    cell_reads: u32 = 0,
    cell_writes: u32 = 0,
    sheet_queries: u32 = 0,
    format_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

pub export fn google_sheets_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

pub export fn google_sheets_mcp_connect(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .connected;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.cell_reads = 0;
            slot.cell_writes = 0;
            slot.sheet_queries = 0;
            slot.format_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn google_sheets_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

pub export fn google_sheets_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

pub export fn google_sheets_mcp_throttle(slot_idx: c_int) c_int {
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

pub export fn google_sheets_mcp_unthrottle(slot_idx: c_int) c_int {
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

pub export fn google_sheets_mcp_signal_error(slot_idx: c_int) c_int {
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

pub export fn google_sheets_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(GoogleSheetsAction, action) catch return -3;

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
        .read_range, .batch_read, .get_named_ranges => sessions[idx].cell_reads += 1,
        .write_range, .append_rows => sessions[idx].cell_writes += 1,
        .get_spreadsheet, .list_sheets, .create_sheet => sessions[idx].sheet_queries += 1,
        .get_conditional_formats, .get_pivot_tables => sessions[idx].format_queries += 1,
    }

    return 0;
}

pub export fn google_sheets_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

pub export fn google_sheets_mcp_cell_read_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.cell_reads);
}

pub export fn google_sheets_mcp_cell_write_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.cell_writes);
}

pub export fn google_sheets_mcp_sheet_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.sheet_queries);
}

pub export fn google_sheets_mcp_format_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.format_queries);
}

pub export fn google_sheets_mcp_action_count() c_int {
    return 10;
}

pub export fn google_sheets_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "connected session lifecycle" {
    google_sheets_mcp_reset();

    const slot = google_sheets_mcp_connect(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_record_call(slot, 1));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_cell_read_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_disconnect(slot));
}

test "requires connected state for actions" {
    google_sheets_mcp_reset();

    const slot = google_sheets_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), google_sheets_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_record_call(slot, 0));
}

test "category counting" {
    google_sheets_mcp_reset();

    const slot = google_sheets_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_record_call(slot, 1)); // ReadRange
    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_record_call(slot, 4)); // WriteRange
    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_record_call(slot, 0)); // GetSpreadsheet
    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_record_call(slot, 8)); // GetConditionalFormats

    try std.testing.expectEqual(@as(c_int, 4), google_sheets_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_cell_read_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_cell_write_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_sheet_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_format_query_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), google_sheets_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_can_transition(2, 3));
    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_can_transition(0, 2));
}

test "slot exhaustion" {
    google_sheets_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = google_sheets_mcp_connect(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), google_sheets_mcp_connect(0));

    try std.testing.expectEqual(@as(c_int, 0), google_sheets_mcp_disconnect(slots[0]));
    const new_slot = google_sheets_mcp_connect(0);
    try std.testing.expect(new_slot >= 0);
}
