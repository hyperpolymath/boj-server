// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BSP-MCP Cartridge — Zig FFI bridge for Build Server Protocol management.
//
// Implements the BSP lifecycle state machine from SafeBsp.idr with build
// target tracking and task status management.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match BspMcp.SafeBsp encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const BspState = enum(c_int) {
    uninitialized = 0,
    initializing = 1,
    ready = 2,
    building = 3,
    shutting_down = 4,
    exited = 5,
};

pub const BuildTargetKind = enum(c_int) {
    library = 1,
    application = 2,
    test_target = 3,
    benchmark = 4,
    integration_test = 5,
    documentation = 6,
};

pub const TaskStatus = enum(c_int) {
    queued = 1,
    started = 2,
    finished = 3,
    cancelled = 4,
    failed = 5,
};

pub const BspCapability = enum(c_int) {
    compile = 1,
    test_cap = 2,
    run = 3,
    debug = 4,
    clean_cache = 5,
    dependency_sources = 6,
    resources = 7,
    output_paths = 8,
    jvm_test_env = 9,
};

// ═══════════════════════════════════════════════════════════════════════
// BSP Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;
const MAX_TARGETS: usize = 32;
const MAX_CAPABILITIES: usize = 9;

const BuildTarget = struct {
    active: bool = false,
    kind: BuildTargetKind = .library,
    task_status: TaskStatus = .queued,
};

const SessionSlot = struct {
    active: bool = false,
    state: BspState = .uninitialized,
    capabilities: [MAX_CAPABILITIES]bool = [_]bool{false} ** MAX_CAPABILITIES,
    targets: [MAX_TARGETS]BuildTarget = [_]BuildTarget{.{}} ** MAX_TARGETS,
    target_count: usize = 0,
    diagnostics_count: usize = 0,
    errors_count: usize = 0,
    warnings_count: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: BspState, to: BspState) bool {
    return switch (from) {
        .uninitialized => to == .initializing,
        .initializing => to == .ready or to == .exited,
        .ready => to == .building or to == .shutting_down,
        .building => to == .ready or to == .shutting_down,
        .shutting_down => to == .exited,
        .exited => false,
    };
}

/// Initialise a new BSP session. Returns slot index or -1 on failure.
pub export fn bsp_init() c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.* = SessionSlot{};
            slot.active = true;
            return @intCast(i);
        }
    }
    return -1;
}

/// Start initialization (Uninitialized -> Initializing).
pub export fn bsp_start_init(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .initializing)) return -2;
    sessions[idx].state = .initializing;
    return 0;
}

/// Register a build capability during initialization.
pub export fn bsp_register_capability(slot_idx: c_int, cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (sessions[idx].state != .initializing) return -2;
    if (cap < 1 or cap > MAX_CAPABILITIES) return -3;
    const cap_idx: usize = @intCast(cap - 1);
    sessions[idx].capabilities[cap_idx] = true;
    return 0;
}

/// Mark initialization complete (Initializing -> Ready).
pub export fn bsp_ready(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .ready)) return -2;
    sessions[idx].state = .ready;
    return 0;
}

/// Start a build (Ready -> Building).
pub export fn bsp_build(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .building)) return -2;
    sessions[idx].state = .building;
    return 0;
}

/// Build complete (Building -> Ready).
pub export fn bsp_build_done(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .ready)) return -2;
    sessions[idx].state = .ready;
    return 0;
}

/// Request shutdown.
pub export fn bsp_shutdown(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .shutting_down)) return -2;
    sessions[idx].state = .shutting_down;
    return 0;
}

/// Exit.
pub export fn bsp_exit(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .exited)) return -2;
    sessions[idx].state = .exited;
    return 0;
}

/// Get the state of a session.
pub export fn bsp_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(BspState.uninitialized);
    return @intFromEnum(sessions[idx].state);
}

/// Can we submit build requests?
pub export fn bsp_can_build(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return 0;
    const idx: usize = @intCast(slot_idx);
    return if (sessions[idx].active and sessions[idx].state == .ready) 1 else 0;
}

/// Is a build in progress?
pub export fn bsp_is_building(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return 0;
    const idx: usize = @intCast(slot_idx);
    return if (sessions[idx].active and sessions[idx].state == .building) 1 else 0;
}

/// Register a build target. Returns target index or -1 on failure.
pub export fn bsp_add_target(slot_idx: c_int, kind: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (sessions[idx].target_count >= MAX_TARGETS) return -2;

    for (&sessions[idx].targets, 0..) |*tgt, ti| {
        if (!tgt.active) {
            tgt.active = true;
            tgt.kind = @enumFromInt(kind);
            tgt.task_status = .queued;
            sessions[idx].target_count += 1;
            return @intCast(ti);
        }
    }
    return -1;
}

/// Check if a session has a specific capability.
pub export fn bsp_has_capability(slot_idx: c_int, cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return 0;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return 0;
    if (cap < 1 or cap > MAX_CAPABILITIES) return 0;
    const cap_idx: usize = @intCast(cap - 1);
    return if (sessions[idx].capabilities[cap_idx]) 1 else 0;
}

/// Validate a state transition (C-ABI export).
pub export fn bsp_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: BspState = @enumFromInt(from);
    const t: BspState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Release a session slot.
pub export fn bsp_release(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    sessions[idx] = SessionSlot{};
    return 0;
}

/// Reset all sessions.
pub export fn bsp_reset_all() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        slot.* = SessionSlot{};
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface
// ═══════════════════════════════════════════════════════════════════════

pub export fn boj_cartridge_init() c_int {
    bsp_reset_all();
    return 0;
}

pub export fn boj_cartridge_deinit() void {
    bsp_reset_all();
}

pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "bsp-mcp";
}

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

    const body: []const u8 =     if (shim.toolIs(tool_name, "bsp_start"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "bsp_initialize"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "bsp_targets"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "bsp_compile"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "bsp_test"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "bsp_run"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "bsp_clean"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "bsp_diagnostics"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "bsp_stop"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "init and release BSP session" {
    bsp_reset_all();
    const slot = bsp_init();
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(BspState.uninitialized)), bsp_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), bsp_release(slot));
}

test "full BSP build lifecycle" {
    bsp_reset_all();
    const slot = bsp_init();
    try std.testing.expectEqual(@as(c_int, 0), bsp_start_init(slot));
    // Register capabilities
    try std.testing.expectEqual(@as(c_int, 0), bsp_register_capability(slot, @intFromEnum(BspCapability.compile)));
    try std.testing.expectEqual(@as(c_int, 0), bsp_register_capability(slot, @intFromEnum(BspCapability.test_cap)));
    try std.testing.expectEqual(@as(c_int, 0), bsp_ready(slot));
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_build(slot));
    // Check capabilities
    try std.testing.expectEqual(@as(c_int, 1), bsp_has_capability(slot, @intFromEnum(BspCapability.compile)));
    try std.testing.expectEqual(@as(c_int, 0), bsp_has_capability(slot, @intFromEnum(BspCapability.debug)));
    // Add targets and build
    try std.testing.expect(bsp_add_target(slot, @intFromEnum(BuildTargetKind.library)) >= 0);
    try std.testing.expectEqual(@as(c_int, 0), bsp_build(slot));
    try std.testing.expectEqual(@as(c_int, 1), bsp_is_building(slot));
    try std.testing.expectEqual(@as(c_int, 0), bsp_can_build(slot));
    // Build done
    try std.testing.expectEqual(@as(c_int, 0), bsp_build_done(slot));
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_build(slot));
    // Shutdown and exit
    try std.testing.expectEqual(@as(c_int, 0), bsp_shutdown(slot));
    try std.testing.expectEqual(@as(c_int, 0), bsp_exit(slot));
}

test "cannot build before ready" {
    bsp_reset_all();
    const slot = bsp_init();
    try std.testing.expectEqual(@as(c_int, 0), bsp_can_build(slot));
    try std.testing.expectEqual(@as(c_int, -2), bsp_build(slot));
}

test "BSP state transitions" {
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_transition(0, 1)); // uninit -> initializing
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_transition(1, 2)); // initializing -> ready
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_transition(2, 3)); // ready -> building
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_transition(3, 2)); // building -> ready
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_transition(2, 4)); // ready -> shutting_down
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_transition(3, 4)); // building -> shutting_down (cancel)
    try std.testing.expectEqual(@as(c_int, 1), bsp_can_transition(4, 5)); // shutting_down -> exited
    try std.testing.expectEqual(@as(c_int, 0), bsp_can_transition(0, 2)); // uninit -> ready (invalid)
    try std.testing.expectEqual(@as(c_int, 0), bsp_can_transition(5, 0)); // exited -> uninit (invalid)
}

test "max BSP sessions enforced" {
    bsp_reset_all();
    var i: usize = 0;
    while (i < MAX_SESSIONS) : (i += 1) {
        try std.testing.expect(bsp_init() >= 0);
    }
    try std.testing.expectEqual(@as(c_int, -1), bsp_init());
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "bsp_start",
        "bsp_initialize",
        "bsp_targets",
        "bsp_compile",
        "bsp_test",
        "bsp_run",
        "bsp_clean",
        "bsp_diagnostics",
        "bsp_stop",
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
    const rc = boj_cartridge_invoke("bsp_start", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
