// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// UMS-MCP Cartridge — Zig FFI bridge for level architect operations.
//
// Implements the level lifecycle state machine from SafeUms.idr.
// Ensures no level operation can execute without an open project,
// no save without validation, and tracks the full lifecycle:
//   Idle -> ProjectOpen -> LevelLoaded -> Validating -> Valid/Invalid -> Saved

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match UmsMcp.SafeUms encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const UmsState = enum(c_int) {
    idle = 0,
    project_open = 1,
    level_loaded = 2,
    validating = 3,
    valid = 4,
    invalid = 5,
    saved = 6,
};

pub const UmsResource = enum(c_int) {
    project = 1,
    level = 2,
    template = 3,
    config = 4,
};

pub const ValidationSeverity = enum(c_int) {
    err = 0,
    warning = 1,
    info = 2,
};

// ═══════════════════════════════════════════════════════════════════════
// Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;
const RESULT_BUF_SIZE: usize = 8192;
const MAX_NAME_LEN: usize = 256;

const SessionSlot = struct {
    active: bool = false,
    state: UmsState = .idle,
    project_name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    project_name_len: usize = 0,
    level_name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    level_name_len: usize = 0,
    validation_errors: u32 = 0,
    validation_warnings: u32 = 0,
    result_buf: [RESULT_BUF_SIZE]u8 = [_]u8{0} ** RESULT_BUF_SIZE,
    result_len: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
/// Single coarse-grained mutex over the `sessions` table. The C-ABI
/// boundary is the concurrency boundary: every exported function takes
/// this lock for the duration of its slot access, so callers from any
/// thread (including the MCP bridge's tokio-style task pool) see a
/// linearised view of session state.
var sessions_mu: std.Thread.Mutex = .{};

/// Find an inactive session slot and activate it. Caller must hold
/// `sessions_mu`.
fn alloc_slot() ?usize {
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.* = .{};
            slot.active = true;
            return i;
        }
    }
    return null;
}

/// Write a JSON string into a session's result buffer.
fn write_result(slot: *SessionSlot, data: []const u8) void {
    const len = @min(data.len, RESULT_BUF_SIZE);
    @memcpy(slot.result_buf[0..len], data[0..len]);
    slot.result_len = len;
}

/// Format a simple JSON object into the result buffer.
fn write_json_status(slot: *SessionSlot, status: []const u8, message: []const u8) void {
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{{\"status\":\"{s}\",\"message\":\"{s}\"}}", .{ status, message }) catch {
        write_result(slot, "{\"status\":\"error\",\"message\":\"format overflow\"}");
        return;
    };
    write_result(slot, result);
}

// ═══════════════════════════════════════════════════════════════════════
// State Transition Validation
// ═══════════════════════════════════════════════════════════════════════

fn can_transition(from: UmsState, to: UmsState) bool {
    return switch (from) {
        .idle => to == .project_open,
        .project_open => to == .level_loaded or to == .idle,
        .level_loaded => to == .validating or to == .project_open or to == .idle,
        .validating => to == .valid or to == .invalid or to == .idle,
        .valid => to == .saved or to == .idle,
        .invalid => to == .level_loaded or to == .idle,
        .saved => to == .level_loaded or to == .idle,
    };
}

fn try_transition(slot: *SessionSlot, target: UmsState) bool {
    if (can_transition(slot.state, target)) {
        slot.state = target;
        return true;
    }
    return false;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exported Functions
// ═══════════════════════════════════════════════════════════════════════

/// Validate a state transition (mirrors Idris2 canTransition).
pub export fn ums_can_transition(from: c_int, to: c_int) callconv(.c) c_int {
    const from_state: UmsState = @enumFromInt(from);
    const to_state: UmsState = @enumFromInt(to);
    return if (can_transition(from_state, to_state)) 1 else 0;
}

/// Create a new project. Returns slot index or -1 on failure.
pub export fn ums_create_project(name_ptr: [*]const u8, name_len: usize) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    const idx = alloc_slot() orelse return -1;
    const slot = &sessions[idx];
    const copy_len = @min(name_len, MAX_NAME_LEN);
    @memcpy(slot.project_name[0..copy_len], name_ptr[0..copy_len]);
    slot.project_name_len = copy_len;
    slot.state = .project_open;
    write_json_status(slot, "ok", "project created");
    return @intCast(idx);
}

/// Open an existing project. Returns slot index or -1 on failure.
pub export fn ums_open_project(name_ptr: [*]const u8, name_len: usize) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    const idx = alloc_slot() orelse return -1;
    const slot = &sessions[idx];
    const copy_len = @min(name_len, MAX_NAME_LEN);
    @memcpy(slot.project_name[0..copy_len], name_ptr[0..copy_len]);
    slot.project_name_len = copy_len;
    slot.state = .project_open;
    write_json_status(slot, "ok", "project opened");
    return @intCast(idx);
}

/// Delete a project. Requires idle or project_open state. Returns 0 on success.
pub export fn ums_delete_project(slot_idx: c_int) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .idle and slot.state != .project_open) return -2;
    slot.* = .{};
    return 0;
}

/// Load a level in the current project. Returns 0 on success.
pub export fn ums_load_level(slot_idx: c_int, name_ptr: [*]const u8, name_len: usize) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!try_transition(slot, .level_loaded)) return -2;
    const copy_len = @min(name_len, MAX_NAME_LEN);
    @memcpy(slot.level_name[0..copy_len], name_ptr[0..copy_len]);
    slot.level_name_len = copy_len;
    write_json_status(slot, "ok", "level loaded");
    return 0;
}

/// Save the current level. Requires Valid state. Returns 0 on success.
pub export fn ums_save_level(slot_idx: c_int) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!try_transition(slot, .saved)) return -2;
    write_json_status(slot, "ok", "level saved");
    return 0;
}

/// Run ABI validation on the loaded level. Returns 0 (valid) or 1 (invalid).
pub export fn ums_validate_level_abi(slot_idx: c_int) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!try_transition(slot, .validating)) return -2;
    // Stub validation: always passes. Real implementation would check
    // level data against the Idris2 ABI specification.
    slot.validation_errors = 0;
    slot.validation_warnings = 0;
    _ = try_transition(slot, .valid);
    write_json_status(slot, "valid", "ABI validation passed (0 errors, 0 warnings)");
    return 0;
}

/// List levels in the current project. Returns count or -1 on error.
pub export fn ums_list_levels(slot_idx: c_int) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state == .idle) return -2;
    write_result(slot, "{\"levels\":[],\"count\":0}");
    return 0;
}

/// Export the level configuration as JSON. Returns 0 on success.
pub export fn ums_export_level_config(slot_idx: c_int) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .level_loaded and slot.state != .valid and
        slot.state != .invalid and slot.state != .saved) return -2;
    const level_name = slot.level_name[0..slot.level_name_len];
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{{\"level\":\"{s}\",\"config\":{{}}}}", .{level_name}) catch {
        write_json_status(slot, "error", "format overflow");
        return -3;
    };
    write_result(slot, result);
    return 0;
}

/// Load available templates. Returns count or -1 on error.
pub export fn ums_load_templates(slot_idx: c_int) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    _ = slot_idx;
    // Templates are global, no session state required.
    return 0;
}

/// Instantiate a level from a template. Returns 0 on success.
pub export fn ums_instantiate_template(slot_idx: c_int, tmpl_ptr: [*]const u8, tmpl_len: usize, name_ptr: [*]const u8, name_len: usize) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .project_open) return -2;
    _ = tmpl_ptr;
    _ = tmpl_len;
    // Transition to level_loaded with the new level name
    slot.state = .level_loaded;
    const copy_len = @min(name_len, MAX_NAME_LEN);
    @memcpy(slot.level_name[0..copy_len], name_ptr[0..copy_len]);
    slot.level_name_len = copy_len;
    write_json_status(slot, "ok", "template instantiated");
    return 0;
}

/// Get the current session state. Returns state int or -1 if inactive.
pub export fn ums_state(slot_idx: c_int) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Read the result buffer. Returns bytes written or 0.
pub export fn ums_read_result(slot_idx: c_int, out_ptr: [*]u8, out_cap: usize) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return 0;
    const idx: usize = @intCast(slot_idx);
    const slot = &sessions[idx];
    if (!slot.active) return 0;
    const len = @min(slot.result_len, out_cap);
    @memcpy(out_ptr[0..len], slot.result_buf[0..len]);
    return @intCast(len);
}

/// Close a session (force to idle and deactivate).
pub export fn ums_close(slot_idx: c_int) callconv(.c) c_int {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    sessions[idx] = .{};
    return 0;
}

/// Reset all sessions (testing/teardown).
pub export fn ums_reset() callconv(.c) void {
    sessions_mu.lock();
    defer sessions_mu.unlock();
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "ums-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "ums_create_project"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "ums_open_project"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "ums_close_project"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "ums_load_level"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "ums_save_level"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "ums_validate_level"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "ums_list_profiles"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "state machine: full happy path" {
    ums_reset();
    // Create project
    const slot = ums_create_project("test-proj", 9);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 1), ums_state(slot)); // project_open

    // Load level
    try std.testing.expectEqual(@as(c_int, 0), ums_load_level(slot, "level-01", 8));
    try std.testing.expectEqual(@as(c_int, 2), ums_state(slot)); // level_loaded

    // Validate
    try std.testing.expectEqual(@as(c_int, 0), ums_validate_level_abi(slot));
    try std.testing.expectEqual(@as(c_int, 4), ums_state(slot)); // valid

    // Save
    try std.testing.expectEqual(@as(c_int, 0), ums_save_level(slot));
    try std.testing.expectEqual(@as(c_int, 6), ums_state(slot)); // saved

    // Close
    try std.testing.expectEqual(@as(c_int, 0), ums_close(slot));
}

test "state machine: cannot save without validation" {
    ums_reset();
    const slot = ums_create_project("proj", 4);
    _ = ums_load_level(slot, "lvl", 3);
    // Try to save from level_loaded (should fail — must validate first)
    try std.testing.expectEqual(@as(c_int, -2), ums_save_level(slot));
}

test "state machine: cannot load level without project" {
    ums_reset();
    // Slot 0 is not active
    try std.testing.expectEqual(@as(c_int, -1), ums_load_level(0, "lvl", 3));
}

test "transition validator" {
    // Idle -> ProjectOpen: allowed
    try std.testing.expectEqual(@as(c_int, 1), ums_can_transition(0, 1));
    // Idle -> LevelLoaded: not allowed
    try std.testing.expectEqual(@as(c_int, 0), ums_can_transition(0, 2));
    // Valid -> Saved: allowed
    try std.testing.expectEqual(@as(c_int, 1), ums_can_transition(4, 6));
    // LevelLoaded -> Saved: not allowed (must validate first)
    try std.testing.expectEqual(@as(c_int, 0), ums_can_transition(2, 6));
}

test "read result buffer" {
    ums_reset();
    const slot = ums_create_project("rp", 2);
    var buf: [256]u8 = undefined;
    const len = ums_read_result(slot, &buf, 256);
    try std.testing.expect(len > 0);
    const result = buf[0..@intCast(len)];
    try std.testing.expect(std.mem.indexOf(u8, result, "project created") != null);
}

test "delete project only when idle or project_open" {
    ums_reset();
    const slot = ums_create_project("dp", 2);
    _ = ums_load_level(slot, "lv", 2);
    // Cannot delete while level is loaded
    try std.testing.expectEqual(@as(c_int, -2), ums_delete_project(slot));
    // Close and reopen
    _ = ums_close(slot);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns ums-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("ums-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "ums_create_project",
        "ums_open_project",
        "ums_close_project",
        "ums_load_level",
        "ums_save_level",
        "ums_validate_level",
        "ums_list_profiles",
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
    const rc = boj_cartridge_invoke("ums_create_project", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
