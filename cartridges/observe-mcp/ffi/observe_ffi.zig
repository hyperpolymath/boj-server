// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Observe-MCP Cartridge — Zig FFI bridge for observability operations.
//
// Implements the metrics pipeline state machine from SafeObserve.idr.
// Ensures no query can execute on an unconfigured source, and tracks
// query counts for backpressure management.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match ObserveMcp.SafeObserve encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const ObserveState = enum(c_int) {
    unconfigured = 0,
    source_registered = 1,
    query_ready = 2,
    querying = 3,
    observe_error = 4,
};

pub const ObserveBackend = enum(c_int) {
    prometheus = 1,
    grafana = 2,
    loki = 3,
    jaeger = 4,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Metrics Pipeline State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SOURCES: usize = 16;

const SourceSlot = struct {
    active: bool,
    backend: ObserveBackend,
    state: ObserveState,
    query_count: u32, // Tracks total queries for rate/backpressure
};

var sources: [MAX_SOURCES]SourceSlot = [_]SourceSlot{.{
    .active = false,
    .backend = .prometheus,
    .state = .unconfigured,
    .query_count = 0,
}} ** MAX_SOURCES;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: ObserveState, to: ObserveState) bool {
    return switch (from) {
        .unconfigured => to == .source_registered,
        .source_registered => to == .query_ready,
        .query_ready => to == .querying or to == .unconfigured,
        .querying => to == .query_ready or to == .observe_error,
        .observe_error => to == .query_ready,
    };
}

/// Register a new observability source. Returns slot index or -1 on failure.
pub export fn obs_register(backend: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sources, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.backend = @enumFromInt(backend);
            slot.state = .source_registered;
            slot.query_count = 0;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Transition a source to query-ready state.
fn readySource(idx: usize) c_int {
    if (!isValidTransition(sources[idx].state, .query_ready)) return -2;
    sources[idx].state = .query_ready;
    return 0;
}

/// Begin a query (transition QueryReady -> Querying).
pub export fn obs_begin_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SOURCES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sources[idx].active) return -1;

    // Auto-transition from source_registered to query_ready if needed
    if (sources[idx].state == .source_registered) {
        const ready_result = readySource(idx);
        if (ready_result != 0) return ready_result;
    }

    if (!isValidTransition(sources[idx].state, .querying)) return -2;

    sources[idx].state = .querying;
    return 0;
}

/// End a query successfully (transition Querying -> QueryReady).
pub export fn obs_end_query(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SOURCES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sources[idx].active) return -1;
    if (!isValidTransition(sources[idx].state, .query_ready)) return -2;

    sources[idx].state = .query_ready;
    sources[idx].query_count += 1;
    return 0;
}

/// Unregister a source (transition QueryReady -> Unconfigured).
pub export fn obs_unregister(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SOURCES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sources[idx].active) return -1;
    if (!isValidTransition(sources[idx].state, .unconfigured)) return -2;

    sources[idx].active = false;
    sources[idx].state = .unconfigured;
    sources[idx].query_count = 0;
    return 0;
}

/// Get the state of a source.
pub export fn obs_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SOURCES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sources[idx].active) return @intFromEnum(ObserveState.unconfigured);
    return @intFromEnum(sources[idx].state);
}

/// Get the query count for a source (for backpressure tracking).
pub export fn obs_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SOURCES) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sources[idx].active) return 0;
    return @intCast(sources[idx].query_count);
}

/// Validate a state transition (C-ABI export).
pub export fn obs_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: ObserveState = @enumFromInt(from);
    const t: ObserveState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sources (for testing).
pub export fn obs_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sources) |*slot| {
        slot.active = false;
        slot.state = .unconfigured;
        slot.query_count = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the observe-mcp cartridge. Resets all source slots.
pub export fn boj_cartridge_init() c_int {
    obs_reset();
    return 0;
}

/// Deinitialise the observe-mcp cartridge. Resets all source slots.
pub export fn boj_cartridge_deinit() void {
    obs_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "observe-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "observe_register"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "observe_query_metrics"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "observe_query_logs"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "observe_query_traces"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "register and unregister" {
    obs_reset();
    const slot = obs_register(@intFromEnum(ObserveBackend.prometheus));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ObserveState.source_registered)), obs_state(slot));
    // Must go through query_ready before unregister
    _ = obs_begin_query(slot); // auto-transitions to query_ready then querying
    _ = obs_end_query(slot); // back to query_ready
    try std.testing.expectEqual(@as(c_int, 0), obs_unregister(slot));
}

test "cannot query unconfigured source" {
    obs_reset();
    // Slot 0 is not active — should fail
    try std.testing.expectEqual(@as(c_int, -1), obs_begin_query(0));
}

test "query lifecycle with count tracking" {
    obs_reset();
    const slot = obs_register(@intFromEnum(ObserveBackend.loki));
    try std.testing.expectEqual(@as(c_int, 0), obs_query_count(slot));
    try std.testing.expectEqual(@as(c_int, 0), obs_begin_query(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(ObserveState.querying)), obs_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), obs_end_query(slot));
    try std.testing.expectEqual(@as(c_int, 1), obs_query_count(slot));
}

test "multiple queries increment count" {
    obs_reset();
    const slot = obs_register(@intFromEnum(ObserveBackend.jaeger));
    _ = obs_begin_query(slot);
    _ = obs_end_query(slot);
    _ = obs_begin_query(slot);
    _ = obs_end_query(slot);
    _ = obs_begin_query(slot);
    _ = obs_end_query(slot);
    try std.testing.expectEqual(@as(c_int, 3), obs_query_count(slot));
}

test "cannot unregister while querying" {
    obs_reset();
    const slot = obs_register(@intFromEnum(ObserveBackend.grafana));
    _ = obs_begin_query(slot);
    // Should fail — can only unregister from query_ready
    try std.testing.expectEqual(@as(c_int, -2), obs_unregister(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), obs_can_transition(0, 1)); // unconfigured -> registered
    try std.testing.expectEqual(@as(c_int, 1), obs_can_transition(1, 2)); // registered -> query_ready
    try std.testing.expectEqual(@as(c_int, 1), obs_can_transition(2, 3)); // query_ready -> querying
    try std.testing.expectEqual(@as(c_int, 1), obs_can_transition(3, 2)); // querying -> query_ready
    try std.testing.expectEqual(@as(c_int, 1), obs_can_transition(2, 0)); // query_ready -> unconfigured
    // Invalid transitions — the key safety invariant
    try std.testing.expectEqual(@as(c_int, 0), obs_can_transition(0, 3)); // unconfigured -> querying (BLOCKED)
    try std.testing.expectEqual(@as(c_int, 0), obs_can_transition(0, 2)); // unconfigured -> query_ready
    try std.testing.expectEqual(@as(c_int, 0), obs_can_transition(3, 0)); // querying -> unconfigured
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "observe_register",
        "observe_query_metrics",
        "observe_query_logs",
        "observe_query_traces",
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
    const rc = boj_cartridge_invoke("observe_register", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
