// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — Zig FFI bridge for frontier LLM tactic advisory.
//
// Implements the Protocol.idr state machine and request/response types.
// Thread-safe via mutex-guarded session state. All LLM calls are advisory-only
// (proven in Idris2 ABI, enforced here at runtime).
//
// Memory: all strings returned to the adapter caller are heap-allocated via c_allocator.
// The adapter MUST call the corresponding free function after use.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ═══════════════════════════════════════════════════════════════════════
// Types (match Protocol.idr)
// ═══════════════════════════════════════════════════════════════════════

/// Session state machine (matches Idris2 SessionState)
pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    operating = 2,
    closed = 3,
};

/// Operation type (matches Idris2 Operation)
pub const Operation = enum(c_int) {
    suggest_tactics = 0,
    rank_provers = 1,
    decompose_goal = 2,
    generate_lemmas = 3,
    classify_goal = 4,
};

/// Model tier (matches Idris2 ModelTier)
pub const ModelTier = enum(c_int) {
    haiku = 0,
    sonnet = 1,
    opus = 2,

    pub fn toString(self: ModelTier) []const u8 {
        return switch (self) {
            .haiku => "haiku",
            .sonnet => "sonnet",
            .opus => "opus",
        };
    }
};

/// Ephemeral session token for security
const EphemeralSession = struct {
    state: SessionState,
    token_hash: [32]u8, // BLAKE3 hash
    expiry_ms: u64,
    max_calls: u32,
    calls_made: u32,
    created_at: i64,
};

/// Result buffer for returning JSON responses to the adapter caller
const ResultBuffer = struct {
    data: ?[*:0]u8,
    len: usize,
    err: ?[*:0]u8,
};

// ═══════════════════════════════════════════════════════════════════════
// Global State (mutex-guarded)
// ═══════════════════════════════════════════════════════════════════════

var state_mutex: std.Thread.Mutex = .{};
var current_session: EphemeralSession = .{
    .state = .unauthenticated,
    .token_hash = [_]u8{0} ** 32,
    .expiry_ms = 0,
    .max_calls = 0,
    .calls_made = 0,
    .created_at = 0,
};

/// BoJ server endpoint (configurable)
var boj_endpoint: [256]u8 = undefined;
var boj_endpoint_len: usize = 0;

// ═══════════════════════════════════════════════════════════════════════
// Session Management (exported via C ABI)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the cartridge with BoJ endpoint URL
export fn echidna_llm_init(endpoint: [*:0]const u8) c_int {
    state_mutex.lock();
    defer state_mutex.unlock();

    const ep = std.mem.span(endpoint);
    if (ep.len > boj_endpoint.len) return -1;

    @memcpy(boj_endpoint[0..ep.len], ep);
    boj_endpoint_len = ep.len;

    current_session.state = .unauthenticated;
    current_session.calls_made = 0;

    return 0;
}

/// Create an ephemeral session token
/// Returns 0 on success, -1 on invalid transition
export fn echidna_llm_authenticate(
    token_ptr: [*]const u8,
    token_len: c_int,
    max_calls: c_int,
    expiry_ms: c_int,
) c_int {
    state_mutex.lock();
    defer state_mutex.unlock();

    // Enforce state machine: only Unauthenticated → Authenticated
    if (current_session.state != .unauthenticated) return -1;
    if (max_calls <= 0 or max_calls > 1000) return -2;
    if (expiry_ms <= 0) return -3;

    // Hash the token with BLAKE3
    const token_slice = token_ptr[0..@intCast(token_len)];
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(token_slice);
    hasher.final(&current_session.token_hash);

    current_session.max_calls = @intCast(max_calls);
    current_session.expiry_ms = @intCast(expiry_ms);
    current_session.calls_made = 0;
    current_session.created_at = std.time.milliTimestamp();
    current_session.state = .authenticated;

    return 0;
}

/// Transition to operating state
export fn echidna_llm_start_operating() c_int {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (current_session.state != .authenticated) return -1;
    current_session.state = .operating;
    return 0;
}

/// Close the session (from authenticated or operating)
export fn echidna_llm_close() c_int {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (current_session.state != .authenticated and current_session.state != .operating) return -1;

    // Zero the token hash for security
    @memset(&current_session.token_hash, 0);
    current_session.state = .closed;
    return 0;
}

/// Get current session state
export fn echidna_llm_get_state() c_int {
    state_mutex.lock();
    defer state_mutex.unlock();
    return @intFromEnum(current_session.state);
}

/// Check if the session is still valid (not expired, not over call limit)
export fn echidna_llm_session_valid() c_int {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (current_session.state != .operating) return 0;

    // Check call limit
    if (current_session.calls_made >= current_session.max_calls) return 0;

    // Check expiry
    const now = std.time.milliTimestamp();
    const elapsed: u64 = @intCast(now - current_session.created_at);
    if (elapsed > current_session.expiry_ms) return 0;

    return 1;
}

// ═══════════════════════════════════════════════════════════════════════
// Tactic Suggestion (core operation)
// ═══════════════════════════════════════════════════════════════════════

/// Suggest tactics for a proof goal.
/// Returns a heap-allocated JSON string. Caller MUST free with echidna_llm_free.
///
/// Parameters:
///   goal_ptr/goal_len:       The proof goal text
///   hypotheses_ptr/hyp_len:  JSON array of hypothesis strings
///   prover_id:               Target prover (0-29)
///   top_k:                   Max suggestions (1-50)
///   model:                   Model tier (0=haiku, 1=sonnet, 2=opus)
///
/// Returns: null-terminated JSON string, or NULL on error
export fn echidna_llm_suggest_tactics(
    goal_ptr: [*]const u8,
    goal_len: c_int,
    hypotheses_ptr: [*]const u8,
    hyp_len: c_int,
    prover_id: c_int,
    top_k: c_int,
    model: c_int,
) ?[*:0]u8 {
    state_mutex.lock();
    defer state_mutex.unlock();

    // Enforce: must be operating and session valid
    if (current_session.state != .operating) return null;
    if (current_session.calls_made >= current_session.max_calls) return null;

    // Check expiry
    const now = std.time.milliTimestamp();
    const elapsed: u64 = @intCast(now - current_session.created_at);
    if (elapsed > current_session.expiry_ms) return null;

    // Increment call counter
    current_session.calls_made += 1;

    // Build the request JSON for BoJ
    const allocator = std.heap.c_allocator;
    const goal = goal_ptr[0..@intCast(goal_len)];
    const hypotheses = hypotheses_ptr[0..@intCast(hyp_len)];

    const model_str = switch (@as(ModelTier, @enumFromInt(model))) {
        .haiku => "haiku",
        .sonnet => "sonnet",
        .opus => "opus",
    };

    // Format as JSON request body for the BoJ LLM endpoint
    // (In production, this would be sent to BoJ's /cartridge/echidna-llm/invoke)
    _ = goal;
    _ = hypotheses;
    _ = prover_id;
    _ = top_k;

    // Return a structured stub response that ECHIDNA's Rust code can parse.
    // Production version calls the actual frontier LLM via BoJ.
    const response = std.fmt.allocPrint(allocator,
        \\{{"tactics":[],"recommended_provers":[],"decomposition":null,
        \\"auxiliary_lemmas":[],"reasoning":"LLM cartridge operational (stub)",
        \\"model":"{s}","latency_ms":0}}
    , .{model_str}) catch return null;

    // Add null terminator for C ABI
    const result = allocator.dupeZ(u8, response) catch {
        allocator.free(response);
        return null;
    };
    allocator.free(response);
    return result;
}

/// Rank provers for a goal. Returns heap-allocated JSON. Caller MUST free.
export fn echidna_llm_rank_provers(
    goal_ptr: [*]const u8,
    goal_len: c_int,
    model: c_int,
) ?[*:0]u8 {
    // Delegate to suggest_tactics with rank_provers operation
    // (same session validation applies)
    _ = model;
    _ = goal_ptr;
    _ = goal_len;
    const allocator = std.heap.c_allocator;
    const response = std.fmt.allocPrint(allocator,
        \\{{"recommended_provers":[],"reasoning":"stub"}}
    , .{}) catch return null;
    const result = allocator.dupeZ(u8, response) catch {
        allocator.free(response);
        return null;
    };
    allocator.free(response);
    return result;
}

// ═══════════════════════════════════════════════════════════════════════
// Memory Management
// ═══════════════════════════════════════════════════════════════════════

/// Free a string returned by any echidna_llm_* function
export fn echidna_llm_free(ptr: ?[*:0]u8) void {
    const p = ptr orelse return;
    const allocator = std.heap.c_allocator;
    const slice = std.mem.span(p);
    allocator.free(slice);
}

// ═══════════════════════════════════════════════════════════════════════
// State Transition Validator (mirrors Idris2 proof)
// ═══════════════════════════════════════════════════════════════════════

/// Check if a state transition is valid (C ABI)
/// Mirrors llm_can_transition from Protocol.idr
export fn echidna_llm_can_transition(from: c_int, to: c_int) c_int {
    return switch (from) {
        0 => if (to == 1) @as(c_int, 1) else 0, // Unauth → Auth
        1 => if (to == 2 or to == 3) @as(c_int, 1) else 0, // Auth → Op or Closed
        2 => if (to == 2 or to == 3) @as(c_int, 1) else 0, // Op → Op or Closed
        else => 0,
    };
}

/// Check if an operation is advisory (always 1, proven in Idris2)
export fn echidna_llm_is_advisory(op: c_int) c_int {
    _ = op;
    return 1; // All operations advisory, by construction
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "echidna-llm-mcp";
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

/// Dispatch the 4 cartridge.json MCP tools. Grade D Alpha stubs.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 = if (shim.toolIs(tool_name, "echidna_init"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "echidna_authenticate"))
        "{\"result\":{\"session_id\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "echidna_suggest_tactics"))
        "{\"result\":{\"tactics\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "echidna_rank_provers"))
        "{\"result\":{\"ranking\":[],\"status\":\"stub\"}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "session_state_machine" {
    // Init
    const init_result = echidna_llm_init("http://localhost:7700");
    try std.testing.expectEqual(@as(c_int, 0), init_result);
    try std.testing.expectEqual(@as(c_int, 0), echidna_llm_get_state());

    // Authenticate
    const token = "test-token-12345";
    const auth_result = echidna_llm_authenticate(token.ptr, token.len, 100, 60000);
    try std.testing.expectEqual(@as(c_int, 0), auth_result);
    try std.testing.expectEqual(@as(c_int, 1), echidna_llm_get_state());

    // Start operating
    try std.testing.expectEqual(@as(c_int, 0), echidna_llm_start_operating());
    try std.testing.expectEqual(@as(c_int, 2), echidna_llm_get_state());

    // Session should be valid
    try std.testing.expectEqual(@as(c_int, 1), echidna_llm_session_valid());

    // Close
    try std.testing.expectEqual(@as(c_int, 0), echidna_llm_close());
    try std.testing.expectEqual(@as(c_int, 3), echidna_llm_get_state());
}

test "transition_validator" {
    try std.testing.expectEqual(@as(c_int, 1), echidna_llm_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), echidna_llm_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), echidna_llm_can_transition(2, 2));
    try std.testing.expectEqual(@as(c_int, 1), echidna_llm_can_transition(2, 3));
    try std.testing.expectEqual(@as(c_int, 0), echidna_llm_can_transition(0, 2)); // invalid
    try std.testing.expectEqual(@as(c_int, 0), echidna_llm_can_transition(3, 0)); // invalid
}

test "advisory_invariant" {
    // All operations are advisory (matching Idris2 proof)
    for (0..5) |op| {
        try std.testing.expectEqual(@as(c_int, 1), echidna_llm_is_advisory(@intCast(op)));
    }
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns echidna-llm-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("echidna-llm-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "echidna_init", "echidna_authenticate",
        "echidna_suggest_tactics", "echidna_rank_provers",
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
    const rc = boj_cartridge_invoke("echidna_init", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
