// SPDX-License-Identifier: MPL-2.0
// OPSM-MCP Cartridge — Zig FFI implementation.
//
// Provides C-compatible functions for the OPSM registry state machine.
// The zig adapter calls these to manage registry connections, execute
// searches, and resolve dependencies.
//
// State machine: Disconnected -> Connected -> Querying -> Idle
//
// Each registry slot holds its current state. Operations that violate
// the state machine return error codes rather than proceeding unsafely.

const std = @import("std");

/// Maximum number of concurrent registry connections.
const MAX_REGISTRIES: usize = 101;

/// Registry connection states (mirrors Idris2 RegState).
const RegState = enum(u8) {
    disconnected = 0,
    connected = 1,
    querying = 2,
    idle = 3,
};

/// Error codes for invalid state transitions.
const OpsmError = enum(i32) {
    ok = 0,
    invalid_slot = -1,
    invalid_transition = -2,
    already_connected = -3,
    not_connected = -4,
    already_querying = -5,
};

/// Per-slot registry state.
const RegistrySlot = struct {
    state: RegState = .disconnected,
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
};

/// Global registry state table.
var slots: [MAX_REGISTRIES]RegistrySlot = [_]RegistrySlot{.{}} ** MAX_REGISTRIES;

// ========================================================================
// C ABI exports
// ========================================================================

/// Connect to a registry. Slot must be in Disconnected state.
export fn opsm_connect(slot_idx: u32) i32 {
    if (slot_idx >= MAX_REGISTRIES) return @intFromEnum(OpsmError.invalid_slot);
    const slot = &slots[slot_idx];
    if (slot.state != .disconnected) return @intFromEnum(OpsmError.already_connected);
    slot.state = .connected;
    return @intFromEnum(OpsmError.ok);
}

/// Begin a query on a connected registry.
export fn opsm_start_query(slot_idx: u32) i32 {
    if (slot_idx >= MAX_REGISTRIES) return @intFromEnum(OpsmError.invalid_slot);
    const slot = &slots[slot_idx];
    if (slot.state != .connected) return @intFromEnum(OpsmError.not_connected);
    slot.state = .querying;
    return @intFromEnum(OpsmError.ok);
}

/// End a query, transitioning to idle.
export fn opsm_end_query(slot_idx: u32) i32 {
    if (slot_idx >= MAX_REGISTRIES) return @intFromEnum(OpsmError.invalid_slot);
    const slot = &slots[slot_idx];
    if (slot.state != .querying) return @intFromEnum(OpsmError.invalid_transition);
    slot.state = .idle;
    return @intFromEnum(OpsmError.ok);
}

/// Reset an idle registry back to connected.
export fn opsm_reset(slot_idx: u32) i32 {
    if (slot_idx >= MAX_REGISTRIES) return @intFromEnum(OpsmError.invalid_slot);
    const slot = &slots[slot_idx];
    if (slot.state != .idle) return @intFromEnum(OpsmError.invalid_transition);
    slot.state = .connected;
    return @intFromEnum(OpsmError.ok);
}

/// Disconnect a registry (from connected or idle state).
export fn opsm_disconnect(slot_idx: u32) i32 {
    if (slot_idx >= MAX_REGISTRIES) return @intFromEnum(OpsmError.invalid_slot);
    const slot = &slots[slot_idx];
    if (slot.state != .connected and slot.state != .idle) {
        return @intFromEnum(OpsmError.not_connected);
    }
    slot.state = .disconnected;
    return @intFromEnum(OpsmError.ok);
}

/// Get the current state of a registry slot.
export fn opsm_state(slot_idx: u32) i32 {
    if (slot_idx >= MAX_REGISTRIES) return @intFromEnum(OpsmError.invalid_slot);
    return @intCast(@intFromEnum(slots[slot_idx].state));
}

/// Check if a state transition is valid.
export fn opsm_can_transition(from: u8, to: u8) i32 {
    const from_state = std.meta.intToEnum(RegState, from) catch return 0;
    const to_state = std.meta.intToEnum(RegState, to) catch return 0;

    const valid = switch (from_state) {
        .disconnected => to_state == .connected,
        .connected => to_state == .querying or to_state == .disconnected,
        .querying => to_state == .idle,
        .idle => to_state == .connected or to_state == .disconnected,
    };

    return if (valid) 1 else 0;
}

/// Reset all registry slots to disconnected.
export fn opsm_reset_all() void {
    for (&slots) |*slot| {
        slot.state = .disconnected;
        slot.name_len = 0;
    }
}

/// Set the name of a registry slot.
export fn opsm_set_name(slot_idx: u32, name_ptr: [*]const u8, name_len: u32) i32 {
    if (slot_idx >= MAX_REGISTRIES) return @intFromEnum(OpsmError.invalid_slot);
    const len = @min(name_len, 128);
    const slot = &slots[slot_idx];
    @memcpy(slot.name[0..len], name_ptr[0..len]);
    slot.name_len = len;
    return @intFromEnum(OpsmError.ok);
}

// ========================================================================
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "opsm-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "opsm_search"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opsm_install"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opsm_resolve"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opsm_info"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opsm_list"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opsm_registries"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "opsm_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ========================================================================

test "connect and disconnect lifecycle" {
    opsm_reset_all();
    try std.testing.expectEqual(@as(i32, 0), opsm_connect(0));
    try std.testing.expectEqual(@as(i32, 1), opsm_state(0));
    try std.testing.expectEqual(@as(i32, 0), opsm_start_query(0));
    try std.testing.expectEqual(@as(i32, 2), opsm_state(0));
    try std.testing.expectEqual(@as(i32, 0), opsm_end_query(0));
    try std.testing.expectEqual(@as(i32, 3), opsm_state(0));
    try std.testing.expectEqual(@as(i32, 0), opsm_disconnect(0));
    try std.testing.expectEqual(@as(i32, 0), opsm_state(0));
}

test "invalid transition rejected" {
    opsm_reset_all();
    // Cannot query a disconnected registry
    try std.testing.expectEqual(@as(i32, -4), opsm_start_query(0));
    // Cannot disconnect a disconnected registry
    try std.testing.expectEqual(@as(i32, -4), opsm_disconnect(0));
}

test "slot bounds checking" {
    try std.testing.expectEqual(@as(i32, -1), opsm_connect(200));
    try std.testing.expectEqual(@as(i32, -1), opsm_state(200));
}

test "transition validity checker" {
    // disconnected -> connected: valid
    try std.testing.expectEqual(@as(i32, 1), opsm_can_transition(0, 1));
    // disconnected -> querying: invalid
    try std.testing.expectEqual(@as(i32, 0), opsm_can_transition(0, 2));
    // connected -> querying: valid
    try std.testing.expectEqual(@as(i32, 1), opsm_can_transition(1, 2));
    // querying -> disconnected: invalid
    try std.testing.expectEqual(@as(i32, 0), opsm_can_transition(2, 0));
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns opsm-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("opsm-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "opsm_search",
        "opsm_install",
        "opsm_resolve",
        "opsm_info",
        "opsm_list",
        "opsm_registries",
        "opsm_status",
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
    const rc = boj_cartridge_invoke("opsm_search", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
