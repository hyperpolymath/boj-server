// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// ML-MCP Cartridge — Zig FFI bridge for ML/AI provider operations.
//
// Implements the provider session state machine from SafeMl.idr.
// Ensures no operation can execute on an unauthenticated provider,
// and tracks credential lifecycle to prevent leaks.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match MlMcp.SafeMl encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    operating = 2,
    auth_error = 3,
};

pub const MlProvider = enum(c_int) {
    hugging_face = 1,
    custom = 99,
};

/// Hugging Face resource types — mirrors `MlMcp.SafeMl.HuggingFaceResource`
/// + `hfResourceToInt` encoding. Declared here so `iseriser abi-verify`
/// can structurally check the encoding against the Idris2 source.
pub const HuggingFaceResource = enum(c_int) {
    hf_model = 1,
    hf_space = 2,
    hf_dataset = 3,
    hf_inference = 4,
};

// ═══════════════════════════════════════════════════════════════════════
// Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;

const RESULT_BUF_SIZE: usize = 4096;

const API_TOKEN_SIZE: usize = 256;

const SessionSlot = struct {
    active: bool,
    state: SessionState,
    provider: MlProvider,
    api_token: [API_TOKEN_SIZE]u8 = [_]u8{0} ** API_TOKEN_SIZE,
    api_token_len: usize = 0,
    result_buf: [RESULT_BUF_SIZE]u8 = [_]u8{0} ** RESULT_BUF_SIZE,
    result_len: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{
    .active = false,
    .state = .unauthenticated,
    .provider = .hugging_face,
    .api_token = [_]u8{0} ** API_TOKEN_SIZE,
    .api_token_len = 0,
    .result_buf = [_]u8{0} ** RESULT_BUF_SIZE,
    .result_len = 0,
}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .operating or to == .unauthenticated,
        .operating => to == .authenticated or to == .auth_error,
        .auth_error => to == .unauthenticated,
    };
}

/// Authenticate with a provider. Returns slot index or -1 on failure.
pub export fn ml_authenticate(provider: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.provider = @enumFromInt(provider);
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Logout from a provider session by slot index.
pub export fn ml_logout(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .unauthenticated)) return -2;

    // Wipe API token on logout
    @memset(&sessions[idx].api_token, 0);
    sessions[idx].api_token_len = 0;
    sessions[idx].active = false;
    sessions[idx].state = .unauthenticated;
    return 0;
}

/// Begin an operation (transition Authenticated -> Operating).
pub export fn ml_begin_operation(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .operating)) return -2;

    sessions[idx].state = .operating;
    return 0;
}

/// End an operation (transition Operating -> Authenticated).
pub export fn ml_end_operation(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .authenticated)) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

/// Get the state of a session.
pub export fn ml_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(SessionState.unauthenticated);
    return @intFromEnum(sessions[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn ml_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: SessionState = @enumFromInt(from);
    const t: SessionState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sessions (for testing).
pub export fn ml_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        @memset(&slot.api_token, 0);
        slot.api_token_len = 0;
        slot.active = false;
        slot.state = .unauthenticated;
        slot.result_len = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the ml-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_init() c_int {
    ml_reset();
    return 0;
}

/// Deinitialise the ml-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_deinit() void {
    ml_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "ml-mcp";
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

/// Dispatch the 4 cartridge.json MCP tools. Grade D Alpha — each arm
/// returns a stub JSON body that reflects the tool's intended shape.
/// `json_args` is ignored here; providers that need args (e.g. the
/// `provider` discriminator in `ml_authenticate`) parse them in a
/// follow-up migration once dispatch is wired end-to-end.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 = if (shim.toolIs(tool_name, "ml_authenticate"))
        "{\"result\":{\"session_id\":0,\"status\":\"stub\",\"note\":\"Grade D Alpha\"}}"
    else if (shim.toolIs(tool_name, "ml_inference"))
        "{\"result\":{\"output\":\"\",\"status\":\"stub\",\"note\":\"Grade D Alpha\"}}"
    else if (shim.toolIs(tool_name, "ml_list_models"))
        "{\"result\":{\"models\":[],\"status\":\"stub\",\"note\":\"Grade D Alpha\"}}"
    else if (shim.toolIs(tool_name, "ml_get_model_info"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\",\"note\":\"Grade D Alpha\"}}"
    else
        return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Hugging Face Provider (provider code 1)
// Grade D Alpha — stub implementations
// Real API: https://huggingface.co/api/{endpoint}
// Auth: Authorization: Bearer {api_token}
// ═══════════════════════════════════════════════════════════════════════

/// Validate that a slot is active, authenticated, and bound to the Hugging Face provider.
fn validateHfSlot(slot_idx: c_int) ?usize {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return null;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return null;
    if (sessions[idx].provider != .hugging_face) return null;
    if (sessions[idx].state != .authenticated) return null;
    return idx;
}

/// Write a JSON stub response into a session's result buffer.
fn writeHfResult(slot: *SessionSlot, endpoint: []const u8, method: []const u8) void {
    const prefix = "{\"provider\":\"huggingface\",\"endpoint\":\"";
    const mid1 = "\",\"method\":\"";
    const mid2 = "\",\"status\":\"stub\",\"note\":\"Grade D Alpha\"}";

    var pos: usize = 0;
    const parts = [_][]const u8{ prefix, endpoint, mid1, method, mid2 };
    for (parts) |part| {
        if (pos + part.len > RESULT_BUF_SIZE) break;
        @memcpy(slot.result_buf[pos .. pos + part.len], part);
        pos += part.len;
    }
    slot.result_len = pos;
}

/// Set API token credentials on a Hugging Face session slot.
pub export fn ml_hf_set_credentials(slot_idx: c_int, token_ptr: [*]const u8, token_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateHfSlot(slot_idx) orelse return -1;
    if (token_len > API_TOKEN_SIZE) return -3;
    @memcpy(sessions[idx].api_token[0..token_len], token_ptr[0..token_len]);
    sessions[idx].api_token_len = token_len;
    return 0;
}

/// Search for models on Hugging Face.
pub export fn ml_hf_search_models(slot_idx: c_int, query_ptr: [*]const u8, query_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateHfSlot(slot_idx) orelse return -1;
    _ = query_ptr[0..query_len];
    writeHfResult(&sessions[idx], "models?search={query}", "GET");
    return 0;
}

/// Get model info from Hugging Face.
pub export fn ml_hf_model_info(slot_idx: c_int, model_id_ptr: [*]const u8, model_id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateHfSlot(slot_idx) orelse return -1;
    _ = model_id_ptr[0..model_id_len];
    writeHfResult(&sessions[idx], "models/{model_id}", "GET");
    return 0;
}

/// Run inference on a Hugging Face model. json_ptr/json_len contain the inference payload.
pub export fn ml_hf_inference(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateHfSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    writeHfResult(&sessions[idx], "models/{model_id}/inference", "POST");
    return 0;
}

/// List Spaces on Hugging Face.
pub export fn ml_hf_list_spaces(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateHfSlot(slot_idx) orelse return -1;
    writeHfResult(&sessions[idx], "spaces", "GET");
    return 0;
}

/// Get Space info from Hugging Face.
pub export fn ml_hf_space_info(slot_idx: c_int, space_id_ptr: [*]const u8, space_id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateHfSlot(slot_idx) orelse return -1;
    _ = space_id_ptr[0..space_id_len];
    writeHfResult(&sessions[idx], "spaces/{space_id}", "GET");
    return 0;
}

/// List datasets on Hugging Face.
pub export fn ml_hf_list_datasets(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateHfSlot(slot_idx) orelse return -1;
    writeHfResult(&sessions[idx], "datasets", "GET");
    return 0;
}

/// Get dataset info from Hugging Face.
pub export fn ml_hf_dataset_info(slot_idx: c_int, dataset_id_ptr: [*]const u8, dataset_id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateHfSlot(slot_idx) orelse return -1;
    _ = dataset_id_ptr[0..dataset_id_len];
    writeHfResult(&sessions[idx], "datasets/{dataset_id}", "GET");
    return 0;
}

/// Read the result buffer for a Hugging Face session slot. Returns length or -1 on error.
pub export fn ml_hf_read_result(slot_idx: c_int, out_ptr: [*]u8, out_cap: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    const len = @min(sessions[idx].result_len, out_cap);
    @memcpy(out_ptr[0..len], sessions[idx].result_buf[0..len]);
    return @intCast(len);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "authenticate and logout" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), ml_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ml_logout(slot));
}

test "cannot operate on unauthenticated" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    _ = ml_logout(slot);
    // Should fail — can't begin operation on unauthenticated session
    try std.testing.expectEqual(@as(c_int, -1), ml_begin_operation(slot));
}

test "operation lifecycle" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    try std.testing.expectEqual(@as(c_int, 0), ml_begin_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.operating)), ml_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ml_end_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), ml_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), ml_logout(slot));
}

test "cannot double-logout" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    _ = ml_logout(slot);
    try std.testing.expectEqual(@as(c_int, -1), ml_logout(slot));
}

test "cannot logout while operating" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    _ = ml_begin_operation(slot);
    try std.testing.expectEqual(@as(c_int, -2), ml_logout(slot));
}

test "state transition validation" {
    try std.testing.expectEqual(@as(c_int, 1), ml_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), ml_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), ml_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 1), ml_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), ml_can_transition(2, 3));
    try std.testing.expectEqual(@as(c_int, 1), ml_can_transition(3, 0));
    try std.testing.expectEqual(@as(c_int, 0), ml_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), ml_can_transition(2, 0));
}

test "max sessions enforced" {
    ml_reset();
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
        try std.testing.expect(s.* >= 0);
    }
    try std.testing.expectEqual(@as(c_int, -1), ml_authenticate(@intFromEnum(MlProvider.hugging_face)));
    _ = ml_logout(slots[0]);
    try std.testing.expect(ml_authenticate(@intFromEnum(MlProvider.hugging_face)) >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// Hugging Face Provider Tests
// ═══════════════════════════════════════════════════════════════════════

test "huggingface auth and credential storage" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), ml_state(slot));
    const token = "hf_test_api_token_abc123";
    try std.testing.expectEqual(@as(c_int, 0), ml_hf_set_credentials(slot, token.ptr, token.len));
    try std.testing.expectEqual(@as(c_int, 0), ml_logout(slot));
}

test "huggingface search models and model info" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    try std.testing.expect(slot >= 0);
    // Search models
    const query = "text-generation";
    try std.testing.expectEqual(@as(c_int, 0), ml_hf_search_models(slot, query.ptr, query.len));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    const len = ml_hf_read_result(slot, &buf, buf.len);
    try std.testing.expect(len > 0);
    const result = buf[0..@intCast(len)];
    try std.testing.expect(std.mem.indexOf(u8, result, "\"provider\":\"huggingface\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"endpoint\":\"models?search={query}\"") != null);
    // Model info
    const model_id = "meta-llama/Llama-2-7b";
    try std.testing.expectEqual(@as(c_int, 0), ml_hf_model_info(slot, model_id.ptr, model_id.len));
    _ = ml_logout(slot);
}

test "huggingface inference and spaces" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    try std.testing.expect(slot >= 0);
    // Inference
    const inference_json = "{\"model\":\"gpt2\",\"inputs\":\"Hello world\"}";
    try std.testing.expectEqual(@as(c_int, 0), ml_hf_inference(slot, inference_json.ptr, inference_json.len));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    var len = ml_hf_read_result(slot, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"endpoint\":\"models/{model_id}/inference\"") != null);
    // List spaces
    try std.testing.expectEqual(@as(c_int, 0), ml_hf_list_spaces(slot));
    len = ml_hf_read_result(slot, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"endpoint\":\"spaces\"") != null);
    // Space info
    const space_id = "stabilityai/stable-diffusion";
    try std.testing.expectEqual(@as(c_int, 0), ml_hf_space_info(slot, space_id.ptr, space_id.len));
    _ = ml_logout(slot);
}

test "huggingface datasets" {
    ml_reset();
    const slot = ml_authenticate(@intFromEnum(MlProvider.hugging_face));
    try std.testing.expect(slot >= 0);
    // List datasets
    try std.testing.expectEqual(@as(c_int, 0), ml_hf_list_datasets(slot));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    var len = ml_hf_read_result(slot, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"endpoint\":\"datasets\"") != null);
    // Dataset info
    const dataset_id = "squad";
    try std.testing.expectEqual(@as(c_int, 0), ml_hf_dataset_info(slot, dataset_id.ptr, dataset_id.len));
    len = ml_hf_read_result(slot, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"endpoint\":\"datasets/{dataset_id}\"") != null);
    _ = ml_logout(slot);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: ml_authenticate returns session_id stub" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("ml_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "session_id") != null);
}

test "invoke: ml_inference returns output stub" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("ml_inference", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "output") != null);
}

test "invoke: ml_list_models returns models array" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("ml_list_models", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "models") != null);
}

test "invoke: ml_get_model_info returns metadata" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("ml_get_model_info", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "metadata") != null);
}

test "invoke: unknown tool returns -1" {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("not_a_tool", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke: buffer too small returns -3 and sets required length" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("ml_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}

test "huggingface wrong-provider rejection" {
    ml_reset();
    // Authenticate as custom, not hugging_face
    const slot = ml_authenticate(@intFromEnum(MlProvider.custom));
    try std.testing.expect(slot >= 0);
    // All HF operations should return -1 (wrong provider)
    const query = "test";
    try std.testing.expectEqual(@as(c_int, -1), ml_hf_search_models(slot, query.ptr, query.len));
    try std.testing.expectEqual(@as(c_int, -1), ml_hf_model_info(slot, query.ptr, query.len));
    const json_data = "{}";
    try std.testing.expectEqual(@as(c_int, -1), ml_hf_inference(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), ml_hf_list_spaces(slot));
    try std.testing.expectEqual(@as(c_int, -1), ml_hf_space_info(slot, query.ptr, query.len));
    try std.testing.expectEqual(@as(c_int, -1), ml_hf_list_datasets(slot));
    try std.testing.expectEqual(@as(c_int, -1), ml_hf_dataset_info(slot, query.ptr, query.len));
    const token = "hf_test";
    try std.testing.expectEqual(@as(c_int, -1), ml_hf_set_credentials(slot, token.ptr, token.len));
    _ = ml_logout(slot);
}
