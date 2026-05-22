// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Research-MCP Cartridge — Zig FFI bridge for academic research provider operations.
//
// Implements the provider session state machine from SafeResearch.idr.
// Ensures no operation can execute on an unauthenticated provider,
// and tracks credential lifecycle to prevent leaks.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match ResearchMcp.SafeResearch encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    operating = 2,
    auth_error = 3,
};

pub const ResearchProvider = enum(c_int) {
    scholar_gateway = 1,
    semantic_scholar = 2,
    open_alex = 3,
    custom = 99,
};

/// Research resource types — mirrors `ResearchMcp.SafeResearch.ResearchResource`
/// + `resResourceToInt` encoding. Declared here so `iseriser abi-verify` can
/// structurally check the encoding against the Idris2 source.
pub const ResearchResource = enum(c_int) {
    res_paper = 1,
    res_author = 2,
    res_citation = 3,
    res_venue = 4,
};

// ═══════════════════════════════════════════════════════════════════════
// Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;

const RESULT_BUF_SIZE: usize = 4096;

const API_KEY_SIZE: usize = 256;

const SessionSlot = struct {
    active: bool,
    state: SessionState,
    provider: ResearchProvider,
    api_key: [API_KEY_SIZE]u8 = [_]u8{0} ** API_KEY_SIZE,
    api_key_len: usize = 0,
    result_buf: [RESULT_BUF_SIZE]u8 = [_]u8{0} ** RESULT_BUF_SIZE,
    result_len: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{
    .active = false,
    .state = .unauthenticated,
    .provider = .scholar_gateway,
    .api_key = [_]u8{0} ** API_KEY_SIZE,
    .api_key_len = 0,
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
pub export fn research_authenticate(provider: c_int) c_int {
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
pub export fn research_logout(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .unauthenticated)) return -2;

    // Wipe API key on logout
    @memset(&sessions[idx].api_key, 0);
    sessions[idx].api_key_len = 0;
    sessions[idx].active = false;
    sessions[idx].state = .unauthenticated;
    return 0;
}

/// Begin an operation (transition Authenticated -> Operating).
pub export fn research_begin_operation(slot_idx: c_int) c_int {
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
pub export fn research_end_operation(slot_idx: c_int) c_int {
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
pub export fn research_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(SessionState.unauthenticated);
    return @intFromEnum(sessions[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn research_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: SessionState = @enumFromInt(from);
    const t: SessionState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sessions (for testing).
pub export fn research_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        @memset(&slot.api_key, 0);
        slot.api_key_len = 0;
        slot.active = false;
        slot.state = .unauthenticated;
        slot.result_len = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the research-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_init() c_int {
    research_reset();
    return 0;
}

/// Deinitialise the research-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_deinit() void {
    research_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "research-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "research_authenticate"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "research_search"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "research_get_paper"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "research_list_providers"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Research Provider Operations (all providers share the same API shape)
// Grade D Alpha — stub implementations
// ═══════════════════════════════════════════════════════════════════════

/// Validate that a slot is active and authenticated (any research provider).
fn validateResearchSlot(slot_idx: c_int) ?usize {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return null;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return null;
    if (sessions[idx].state != .authenticated) return null;
    return idx;
}

/// Get the provider name string for JSON output.
fn providerName(provider: ResearchProvider) []const u8 {
    return switch (provider) {
        .scholar_gateway => "scholar_gateway",
        .semantic_scholar => "semantic_scholar",
        .open_alex => "open_alex",
        .custom => "custom",
    };
}

/// Write a JSON stub response into a session's result buffer.
fn writeResearchResult(slot: *SessionSlot, endpoint: []const u8, method: []const u8) void {
    const prefix = "{\"provider\":\"";
    const mid0 = "\",\"endpoint\":\"";
    const mid1 = "\",\"method\":\"";
    const mid2 = "\",\"status\":\"stub\",\"note\":\"Grade D Alpha\"}";

    const pname = providerName(slot.provider);

    var pos: usize = 0;
    const parts = [_][]const u8{ prefix, pname, mid0, endpoint, mid1, method, mid2 };
    for (parts) |part| {
        if (pos + part.len > RESULT_BUF_SIZE) break;
        @memcpy(slot.result_buf[pos .. pos + part.len], part);
        pos += part.len;
    }
    slot.result_len = pos;
}

/// Set API key credentials on a research session slot.
pub export fn research_set_credentials(slot_idx: c_int, key_ptr: [*]const u8, key_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateResearchSlot(slot_idx) orelse return -1;
    if (key_len > API_KEY_SIZE) return -3;
    @memcpy(sessions[idx].api_key[0..key_len], key_ptr[0..key_len]);
    sessions[idx].api_key_len = key_len;
    return 0;
}

/// Search for papers. query_ptr/query_len contain the search query.
pub export fn research_search_papers(slot_idx: c_int, query_ptr: [*]const u8, query_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateResearchSlot(slot_idx) orelse return -1;
    _ = query_ptr[0..query_len];
    writeResearchResult(&sessions[idx], "papers?query={q}", "GET");
    return 0;
}

/// Get paper details by ID.
pub export fn research_paper_details(slot_idx: c_int, id_ptr: [*]const u8, id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateResearchSlot(slot_idx) orelse return -1;
    _ = id_ptr[0..id_len];
    writeResearchResult(&sessions[idx], "papers/{id}", "GET");
    return 0;
}

/// Get citations for a paper by ID.
pub export fn research_paper_citations(slot_idx: c_int, id_ptr: [*]const u8, id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateResearchSlot(slot_idx) orelse return -1;
    _ = id_ptr[0..id_len];
    writeResearchResult(&sessions[idx], "papers/{id}/citations", "GET");
    return 0;
}

/// Get references from a paper by ID.
pub export fn research_paper_references(slot_idx: c_int, id_ptr: [*]const u8, id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateResearchSlot(slot_idx) orelse return -1;
    _ = id_ptr[0..id_len];
    writeResearchResult(&sessions[idx], "papers/{id}/references", "GET");
    return 0;
}

/// Search for authors by name.
pub export fn research_author_search(slot_idx: c_int, name_ptr: [*]const u8, name_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateResearchSlot(slot_idx) orelse return -1;
    _ = name_ptr[0..name_len];
    writeResearchResult(&sessions[idx], "authors?query={name}", "GET");
    return 0;
}

/// Get papers by an author ID.
pub export fn research_author_papers(slot_idx: c_int, id_ptr: [*]const u8, id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateResearchSlot(slot_idx) orelse return -1;
    _ = id_ptr[0..id_len];
    writeResearchResult(&sessions[idx], "authors/{id}/papers", "GET");
    return 0;
}

/// Read the result buffer for a research session slot. Returns length or -1 on error.
pub export fn research_read_result(slot_idx: c_int, out_ptr: [*]u8, out_cap: usize) c_int {
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
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.scholar_gateway));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), research_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), research_logout(slot));
}

test "cannot operate on unauthenticated" {
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.semantic_scholar));
    _ = research_logout(slot);
    try std.testing.expectEqual(@as(c_int, -1), research_begin_operation(slot));
}

test "operation lifecycle" {
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.open_alex));
    try std.testing.expectEqual(@as(c_int, 0), research_begin_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.operating)), research_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), research_end_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), research_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), research_logout(slot));
}

test "cannot double-logout" {
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.scholar_gateway));
    _ = research_logout(slot);
    try std.testing.expectEqual(@as(c_int, -1), research_logout(slot));
}

test "cannot logout while operating" {
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.semantic_scholar));
    _ = research_begin_operation(slot);
    try std.testing.expectEqual(@as(c_int, -2), research_logout(slot));
}

test "state transition validation" {
    try std.testing.expectEqual(@as(c_int, 1), research_can_transition(0, 1));
    try std.testing.expectEqual(@as(c_int, 1), research_can_transition(1, 2));
    try std.testing.expectEqual(@as(c_int, 1), research_can_transition(2, 1));
    try std.testing.expectEqual(@as(c_int, 1), research_can_transition(1, 0));
    try std.testing.expectEqual(@as(c_int, 1), research_can_transition(2, 3));
    try std.testing.expectEqual(@as(c_int, 1), research_can_transition(3, 0));
    try std.testing.expectEqual(@as(c_int, 0), research_can_transition(0, 2));
    try std.testing.expectEqual(@as(c_int, 0), research_can_transition(2, 0));
}

test "max sessions enforced" {
    research_reset();
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = research_authenticate(@intFromEnum(ResearchProvider.scholar_gateway));
        try std.testing.expect(s.* >= 0);
    }
    try std.testing.expectEqual(@as(c_int, -1), research_authenticate(@intFromEnum(ResearchProvider.scholar_gateway)));
    _ = research_logout(slots[0]);
    try std.testing.expect(research_authenticate(@intFromEnum(ResearchProvider.scholar_gateway)) >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// Scholar Gateway Provider Tests
// ═══════════════════════════════════════════════════════════════════════

test "scholar gateway auth and credential storage" {
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.scholar_gateway));
    try std.testing.expect(slot >= 0);
    const key = "sg_test_api_key_abc123";
    try std.testing.expectEqual(@as(c_int, 0), research_set_credentials(slot, key.ptr, key.len));
    try std.testing.expectEqual(@as(c_int, 0), research_logout(slot));
}

test "scholar gateway search papers and details" {
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.scholar_gateway));
    try std.testing.expect(slot >= 0);
    // Search papers
    const query = "dependent types";
    try std.testing.expectEqual(@as(c_int, 0), research_search_papers(slot, query.ptr, query.len));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    const len = research_read_result(slot, &buf, buf.len);
    try std.testing.expect(len > 0);
    const result = buf[0..@intCast(len)];
    try std.testing.expect(std.mem.indexOf(u8, result, "\"provider\":\"scholar_gateway\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"endpoint\":\"papers?query={q}\"") != null);
    // Paper details
    const paper_id = "10.1145/3371098";
    try std.testing.expectEqual(@as(c_int, 0), research_paper_details(slot, paper_id.ptr, paper_id.len));
    _ = research_logout(slot);
}

test "semantic scholar citations and references" {
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.semantic_scholar));
    try std.testing.expect(slot >= 0);
    const paper_id = "649def34f8be52c8b66281af98ae884c09aef38b";
    // Citations
    try std.testing.expectEqual(@as(c_int, 0), research_paper_citations(slot, paper_id.ptr, paper_id.len));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    var len = research_read_result(slot, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"provider\":\"semantic_scholar\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"endpoint\":\"papers/{id}/citations\"") != null);
    // References
    try std.testing.expectEqual(@as(c_int, 0), research_paper_references(slot, paper_id.ptr, paper_id.len));
    len = research_read_result(slot, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"endpoint\":\"papers/{id}/references\"") != null);
    _ = research_logout(slot);
}

test "open alex author search and papers" {
    research_reset();
    const slot = research_authenticate(@intFromEnum(ResearchProvider.open_alex));
    try std.testing.expect(slot >= 0);
    // Author search
    const name = "Edwin Brady";
    try std.testing.expectEqual(@as(c_int, 0), research_author_search(slot, name.ptr, name.len));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    var len = research_read_result(slot, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"provider\":\"open_alex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"endpoint\":\"authors?query={name}\"") != null);
    // Author papers
    const author_id = "A12345678";
    try std.testing.expectEqual(@as(c_int, 0), research_author_papers(slot, author_id.ptr, author_id.len));
    len = research_read_result(slot, &buf, buf.len);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(len)], "\"endpoint\":\"authors/{id}/papers\"") != null);
    _ = research_logout(slot);
}

test "research all providers credential storage" {
    research_reset();
    // Test credentials work with all three providers
    const providers = [_]ResearchProvider{ .scholar_gateway, .semantic_scholar, .open_alex };
    for (providers) |prov| {
        const slot = research_authenticate(@intFromEnum(prov));
        try std.testing.expect(slot >= 0);
        const key = "test_key_123";
        try std.testing.expectEqual(@as(c_int, 0), research_set_credentials(slot, key.ptr, key.len));
        try std.testing.expectEqual(@as(c_int, 0), research_logout(slot));
    }
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "research_authenticate",
        "research_search",
        "research_get_paper",
        "research_list_providers",
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
    const rc = boj_cartridge_invoke("research_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
