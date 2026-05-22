// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// LSP-MCP Cartridge — Zig FFI bridge for Language Server Protocol management.
//
// Implements the LSP lifecycle state machine from SafeLsp.idr.
// Tracks up to 8 concurrent LSP server sessions with capability negotiation.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match LspMcp.SafeLsp encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const LspState = enum(c_int) {
    uninitialized = 0,
    initializing = 1,
    running = 2,
    shutting_down = 3,
    exited = 4,
};

pub const ServerCapability = enum(c_int) {
    text_doc_sync = 1,
    completion = 2,
    hover = 3,
    signature_help = 4,
    definition = 5,
    references = 6,
    document_symbol = 7,
    code_action = 8,
    diagnostics = 9,
    formatting = 10,
    rename = 11,
    semantic_tokens = 12,
};

pub const DiagnosticSeverity = enum(c_int) {
    err = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

pub const CompletionKind = enum(c_int) {
    text = 1,
    method = 2,
    function = 3,
    constructor = 4,
    field = 5,
    variable = 6,
    class = 7,
    interface = 8,
    module = 9,
    property = 10,
    keyword = 14,
    snippet = 15,
};

// ═══════════════════════════════════════════════════════════════════════
// LSP Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;
const MAX_CAPABILITIES: usize = 12;

const SessionSlot = struct {
    active: bool = false,
    state: LspState = .uninitialized,
    capabilities: [MAX_CAPABILITIES]bool = [_]bool{false} ** MAX_CAPABILITIES,
    capability_count: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: LspState, to: LspState) bool {
    return switch (from) {
        .uninitialized => to == .initializing,
        .initializing => to == .running or to == .exited,
        .running => to == .shutting_down or to == .exited,
        .shutting_down => to == .exited,
        .exited => false,
    };
}

/// Initialise a new LSP session. Returns slot index or -1 on failure.
pub export fn lsp_init() c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.* = SessionSlot{};
            slot.active = true;
            slot.state = .uninitialized;
            return @intCast(i);
        }
    }
    return -1;
}

/// Transition to initializing (Uninitialized -> Initializing).
pub export fn lsp_start_init(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .initializing)) return -2;
    sessions[idx].state = .initializing;
    return 0;
}

/// Register a capability during initialization.
pub export fn lsp_register_capability(slot_idx: c_int, cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (sessions[idx].state != .initializing) return -2;
    if (cap < 1 or cap > MAX_CAPABILITIES) return -3;
    const cap_idx: usize = @intCast(cap - 1);
    sessions[idx].capabilities[cap_idx] = true;
    sessions[idx].capability_count += 1;
    return 0;
}

/// Mark initialization complete (Initializing -> Running).
pub export fn lsp_initialized(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .running)) return -2;
    sessions[idx].state = .running;
    return 0;
}

/// Request shutdown (Running -> ShuttingDown).
pub export fn lsp_shutdown(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .shutting_down)) return -2;
    sessions[idx].state = .shutting_down;
    return 0;
}

/// Exit (ShuttingDown/Running/Initializing -> Exited).
pub export fn lsp_exit(slot_idx: c_int) c_int {
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
pub export fn lsp_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(LspState.uninitialized);
    return @intFromEnum(sessions[idx].state);
}

/// Check if a session has a specific capability.
pub export fn lsp_has_capability(slot_idx: c_int, cap: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return 0;
    if (cap < 1 or cap > MAX_CAPABILITIES) return 0;
    const cap_idx: usize = @intCast(cap - 1);
    return if (sessions[idx].capabilities[cap_idx]) 1 else 0;
}

/// Validate a state transition (C-ABI export).
pub export fn lsp_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: LspState = @enumFromInt(from);
    const t: LspState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Release a session slot.
pub export fn lsp_release(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    sessions[idx] = SessionSlot{};
    return 0;
}

/// Reset all sessions (for testing).
pub export fn lsp_reset_all() void {
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
    lsp_reset_all();
    return 0;
}

pub export fn boj_cartridge_deinit() void {
    lsp_reset_all();
}

pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "lsp-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "lsp_start"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_initialize"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_open"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_change"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_close"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_hover"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_complete"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_goto_def"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_references"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_diagnostics"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_format"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "lsp_stop"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "init and release LSP session" {
    lsp_reset_all();
    const slot = lsp_init();
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(LspState.uninitialized)), lsp_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), lsp_release(slot));
}

test "full LSP lifecycle" {
    lsp_reset_all();
    const slot = lsp_init();
    try std.testing.expectEqual(@as(c_int, 0), lsp_start_init(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(LspState.initializing)), lsp_state(slot));
    // Register capabilities during init
    try std.testing.expectEqual(@as(c_int, 0), lsp_register_capability(slot, @intFromEnum(ServerCapability.completion)));
    try std.testing.expectEqual(@as(c_int, 0), lsp_register_capability(slot, @intFromEnum(ServerCapability.hover)));
    try std.testing.expectEqual(@as(c_int, 0), lsp_initialized(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(LspState.running)), lsp_state(slot));
    // Check capabilities
    try std.testing.expectEqual(@as(c_int, 1), lsp_has_capability(slot, @intFromEnum(ServerCapability.completion)));
    try std.testing.expectEqual(@as(c_int, 1), lsp_has_capability(slot, @intFromEnum(ServerCapability.hover)));
    try std.testing.expectEqual(@as(c_int, 0), lsp_has_capability(slot, @intFromEnum(ServerCapability.rename)));
    // Shutdown and exit
    try std.testing.expectEqual(@as(c_int, 0), lsp_shutdown(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(LspState.shutting_down)), lsp_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), lsp_exit(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(LspState.exited)), lsp_state(slot));
}

test "cannot register capability after init" {
    lsp_reset_all();
    const slot = lsp_init();
    _ = lsp_start_init(slot);
    _ = lsp_initialized(slot);
    // Should fail — not in initializing state
    try std.testing.expectEqual(@as(c_int, -2), lsp_register_capability(slot, @intFromEnum(ServerCapability.definition)));
}

test "LSP state transitions" {
    try std.testing.expectEqual(@as(c_int, 1), lsp_can_transition(0, 1)); // uninit -> initializing
    try std.testing.expectEqual(@as(c_int, 1), lsp_can_transition(1, 2)); // initializing -> running
    try std.testing.expectEqual(@as(c_int, 1), lsp_can_transition(2, 3)); // running -> shutting_down
    try std.testing.expectEqual(@as(c_int, 1), lsp_can_transition(3, 4)); // shutting_down -> exited
    try std.testing.expectEqual(@as(c_int, 1), lsp_can_transition(2, 4)); // running -> exited (dirty)
    try std.testing.expectEqual(@as(c_int, 0), lsp_can_transition(0, 2)); // uninit -> running (invalid)
    try std.testing.expectEqual(@as(c_int, 0), lsp_can_transition(4, 0)); // exited -> uninit (invalid)
}

test "max LSP sessions enforced" {
    lsp_reset_all();
    var i: usize = 0;
    while (i < MAX_SESSIONS) : (i += 1) {
        try std.testing.expect(lsp_init() >= 0);
    }
    try std.testing.expectEqual(@as(c_int, -1), lsp_init());
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "lsp_start",
        "lsp_initialize",
        "lsp_open",
        "lsp_change",
        "lsp_close",
        "lsp_hover",
        "lsp_complete",
        "lsp_goto_def",
        "lsp_references",
        "lsp_diagnostics",
        "lsp_format",
        "lsp_stop",
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
    const rc = boj_cartridge_invoke("lsp_start", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
