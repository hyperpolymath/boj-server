// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// k9iser-mcp Cartridge — Zig FFI bridge for the K9-contract regeneration
// pipeline.
//
// Implements the pipeline state machine from SafeK9iser.idr. Ensures no
// contract set can be applied (committed back to a repo) without first
// passing validation, and none can be validated without being generated.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match K9iserMcp.SafeK9iser encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const K9State = enum(c_int) {
    empty = 0,
    manifest_loaded = 1,
    generated = 2,
    validated = 3,
    applied = 4,
    k9_error = 5,
};

pub const K9Format = enum(c_int) {
    toml = 1,
    yaml = 2,
    json = 3,
    ini = 4,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Regeneration Pipeline State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;

const SessionSlot = struct {
    active: bool,
    format: K9Format,
    state: K9State,
    manifest_hash: u32, // Hash of the manifest for cache invalidation
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{
    .active = false,
    .format = .toml,
    .state = .empty,
    .manifest_hash = 0,
}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: K9State, to: K9State) bool {
    return switch (from) {
        .empty => to == .manifest_loaded,
        .manifest_loaded => to == .generated or to == .k9_error,
        .generated => to == .generated or to == .validated or to == .k9_error,
        .validated => to == .applied or to == .empty,
        .applied => to == .empty,
        .k9_error => to == .empty,
    };
}

/// Load a manifest into a new session. Returns slot index or -1 on failure.
pub export fn k9_load_manifest(format: c_int, manifest_hash: u32) c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.format = @enumFromInt(format);
            slot.state = .manifest_loaded;
            slot.manifest_hash = manifest_hash;
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Generate K9 contracts from the loaded manifest + configs.
pub export fn k9_generate(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .generated)) return -2;

    sessions[idx].state = .generated;
    return 0;
}

/// Validate generated contracts. REQUIRES state to be Generated.
pub export fn k9_validate(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    // SAFETY: Must be in Generated state — cannot validate absent output
    if (sessions[idx].state != .generated) return -2;
    if (!isValidTransition(sessions[idx].state, .validated)) return -2;

    sessions[idx].state = .validated;
    return 0;
}

/// Apply (commit + push) the regenerated contracts. REQUIRES Validated.
/// Key safety invariant: contracts that failed validation can never be
/// pushed back to a repository.
pub export fn k9_apply(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    // SAFETY: Must be in Validated state — cannot skip validation
    if (sessions[idx].state != .validated) return -2;
    if (!isValidTransition(sessions[idx].state, .applied)) return -2;

    sessions[idx].state = .applied;
    return 0;
}

/// Mark a generation/parse error.
pub export fn k9_mark_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .k9_error)) return -2;

    sessions[idx].state = .k9_error;
    return 0;
}

/// Clean the session and reset to Empty.
pub export fn k9_clean(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .empty)) return -2;

    sessions[idx].active = false;
    sessions[idx].state = .empty;
    sessions[idx].manifest_hash = 0;
    return 0;
}

/// Get the state of a session.
pub export fn k9_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(K9State.empty);
    return @intFromEnum(sessions[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn k9_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: K9State = @enumFromInt(from);
    const t: K9State = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sessions (for testing).
pub export fn k9_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        slot.active = false;
        slot.state = .empty;
        slot.manifest_hash = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the k9iser-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_init() c_int {
    k9_reset();
    return 0;
}

/// Deinitialise the k9iser-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_deinit() void {
    k9_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "k9iser-mcp";
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
pub export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 = if (shim.toolIs(tool_name, "k9_load_manifest"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "k9_generate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "k9_validate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "k9_apply"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "k9_clean"))
        "{\"result\":{\"status\":\"stub\"}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "load manifest and clean blocked before validate" {
    k9_reset();
    const slot = k9_load_manifest(@intFromEnum(K9Format.toml), 0xABCD);
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.manifest_loaded)), k9_state(slot));
    // Cannot clean from manifest_loaded (must generate+validate or error first)
    try std.testing.expectEqual(@as(c_int, -2), k9_clean(slot));
}

test "cannot apply without validate" {
    k9_reset();
    const slot = k9_load_manifest(@intFromEnum(K9Format.yaml), 0x1234);
    _ = k9_generate(slot);
    // Attempt to apply directly from generated — MUST fail
    try std.testing.expectEqual(@as(c_int, -2), k9_apply(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.generated)), k9_state(slot));
}

test "cannot validate without generate" {
    k9_reset();
    const slot = k9_load_manifest(@intFromEnum(K9Format.json), 0x5678);
    // Attempt to validate from manifest_loaded — MUST fail
    try std.testing.expectEqual(@as(c_int, -2), k9_validate(slot));
}

test "full pipeline: load -> generate -> validate -> apply -> clean" {
    k9_reset();
    const slot = k9_load_manifest(@intFromEnum(K9Format.toml), 0xCAFE);
    try std.testing.expectEqual(@as(c_int, 0), k9_generate(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.generated)), k9_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), k9_validate(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.validated)), k9_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), k9_apply(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.applied)), k9_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), k9_clean(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.empty)), k9_state(slot));
}

test "regenerate allowed" {
    k9_reset();
    const slot = k9_load_manifest(@intFromEnum(K9Format.toml), 0xAAAA);
    try std.testing.expectEqual(@as(c_int, 0), k9_generate(slot));
    try std.testing.expectEqual(@as(c_int, 0), k9_generate(slot)); // regenerate
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.generated)), k9_state(slot));
}

test "error then recover" {
    k9_reset();
    const slot = k9_load_manifest(@intFromEnum(K9Format.ini), 0xBBBB);
    _ = k9_generate(slot);
    try std.testing.expectEqual(@as(c_int, 0), k9_mark_error(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.k9_error)), k9_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), k9_clean(slot)); // recover
    try std.testing.expectEqual(@as(c_int, @intFromEnum(K9State.empty)), k9_state(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), k9_can_transition(0, 1)); // empty -> manifest_loaded
    try std.testing.expectEqual(@as(c_int, 1), k9_can_transition(1, 2)); // manifest_loaded -> generated
    try std.testing.expectEqual(@as(c_int, 1), k9_can_transition(2, 3)); // generated -> validated
    try std.testing.expectEqual(@as(c_int, 1), k9_can_transition(3, 4)); // validated -> applied
    try std.testing.expectEqual(@as(c_int, 1), k9_can_transition(4, 0)); // applied -> empty
    try std.testing.expectEqual(@as(c_int, 1), k9_can_transition(2, 2)); // regenerate
    // Invalid transitions — the key safety invariants
    try std.testing.expectEqual(@as(c_int, 0), k9_can_transition(1, 3)); // manifest_loaded -> validated (BLOCKED)
    try std.testing.expectEqual(@as(c_int, 0), k9_can_transition(2, 4)); // generated -> applied (BLOCKED)
    try std.testing.expectEqual(@as(c_int, 0), k9_can_transition(0, 4)); // empty -> applied
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "k9_load_manifest",
        "k9_generate",
        "k9_validate",
        "k9_apply",
        "k9_clean",
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
    const rc = boj_cartridge_invoke("k9_load_manifest", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
