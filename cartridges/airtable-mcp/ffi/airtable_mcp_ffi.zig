// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// airtable_mcp_ffi.zig — C-ABI FFI implementation for airtable-mcp cartridge.
//
// Implements the state machine defined in AirtableMcp.SafeRegistry (Idris2 ABI).
// State machine: Disconnected | Connected | RateLimited | Error
// Auth: Required Bearer token (personal access token).
// REST API: https://api.airtable.com/v0
// Actions: ListBases, GetBaseSchema, ListRecords, GetRecord,
//          CreateRecord, UpdateRecord, ListFields, ListViews,
//          ListWebhooks, GetComments
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

pub const AirtableAction = enum(c_int) {
    list_bases = 0,
    get_base_schema = 1,
    list_records = 2,
    get_record = 3,
    create_record = 4,
    update_record = 5,
    list_fields = 6,
    list_views = 7,
    list_webhooks = 8,
    get_comments = 9,
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
    record_reads: u32 = 0,
    record_writes: u32 = 0,
    schema_queries: u32 = 0,
    meta_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

pub export fn airtable_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

pub export fn airtable_mcp_connect(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .connected;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.record_reads = 0;
            slot.record_writes = 0;
            slot.schema_queries = 0;
            slot.meta_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

pub export fn airtable_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

pub export fn airtable_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

pub export fn airtable_mcp_throttle(slot_idx: c_int) c_int {
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

pub export fn airtable_mcp_unthrottle(slot_idx: c_int) c_int {
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

pub export fn airtable_mcp_signal_error(slot_idx: c_int) c_int {
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

pub export fn airtable_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(AirtableAction, action) catch return -3;

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
        .list_records, .get_record, .get_comments => sessions[idx].record_reads += 1,
        .create_record, .update_record => sessions[idx].record_writes += 1,
        .get_base_schema, .list_fields, .list_views => sessions[idx].schema_queries += 1,
        .list_bases, .list_webhooks => sessions[idx].meta_queries += 1,
    }

    return 0;
}

pub export fn airtable_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

pub export fn airtable_mcp_record_read_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.record_reads);
}

pub export fn airtable_mcp_record_write_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.record_writes);
}

pub export fn airtable_mcp_schema_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.schema_queries);
}

pub export fn airtable_mcp_meta_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.meta_queries);
}

pub export fn airtable_mcp_action_count() c_int {
    return 10;
}

pub export fn airtable_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "connected session lifecycle" {
    airtable_mcp_reset();

    const slot = airtable_mcp_connect(0);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_record_call(slot, 2));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_record_read_count(slot));

    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_disconnect(slot));
}

test "requires connected state for actions" {
    airtable_mcp_reset();

    const slot = airtable_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), airtable_mcp_record_call(slot, 0));

    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_record_call(slot, 0));
}

test "category counting" {
    airtable_mcp_reset();

    const slot = airtable_mcp_connect(0);
    try std.testing.expect(slot >= 0);

    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_record_call(slot, 2)); // ListRecords
    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_record_call(slot, 4)); // CreateRecord
    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_record_call(slot, 1)); // GetBaseSchema
    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_record_call(slot, 0)); // ListBases

    try std.testing.expectEqual(@as(c_int, 4), airtable_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_record_read_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_record_write_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_schema_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_meta_query_count(slot));
}

test "transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), airtable_mcp_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_can_transition(2, 3));
    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_can_transition(0, 2));
}

test "slot exhaustion" {
    airtable_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = airtable_mcp_connect(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), airtable_mcp_connect(0));

    try std.testing.expectEqual(@as(c_int, 0), airtable_mcp_disconnect(slots[0]));
    const new_slot = airtable_mcp_connect(0);
    try std.testing.expect(new_slot >= 0);
}
