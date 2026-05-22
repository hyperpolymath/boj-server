// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Comms-MCP Cartridge — Zig FFI bridge for communications provider operations.
//
// Implements the provider session state machine from SafeComms.idr.
// Ensures no operation can execute on an unauthenticated provider,
// and tracks credential lifecycle to prevent leaks.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match CommsMcp.SafeComms encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    operating = 2,
    auth_error = 3,
};

pub const CommsProvider = enum(c_int) {
    gmail = 1,
    google_calendar = 2,
    custom = 99,
};

/// Gmail resource types — mirrors `CommsMcp.SafeComms.GmailResource`
/// + `gmResourceToInt` encoding. Declared here so `iseriser abi-verify`
/// can structurally check the encoding against the Idris2 source.
pub const GmailResource = enum(c_int) {
    gm_message = 1,
    gm_thread = 2,
    gm_label = 3,
    gm_draft = 4,
};

/// Google Calendar resource types — mirrors
/// `CommsMcp.SafeComms.CalendarResource` + `calResourceToInt` encoding.
pub const CalendarResource = enum(c_int) {
    cal_event = 1,
    cal_calendar = 2,
    cal_free_busy = 3,
};

// ═══════════════════════════════════════════════════════════════════════
// Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;

const RESULT_BUF_SIZE: usize = 4096;

const OAUTH_TOKEN_SIZE: usize = 2048;

const SessionSlot = struct {
    active: bool,
    state: SessionState,
    provider: CommsProvider,
    oauth_token: [OAUTH_TOKEN_SIZE]u8 = [_]u8{0} ** OAUTH_TOKEN_SIZE,
    oauth_token_len: usize = 0,
    result_buf: [RESULT_BUF_SIZE]u8 = [_]u8{0} ** RESULT_BUF_SIZE,
    result_len: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{
    .active = false,
    .state = .unauthenticated,
    .provider = .gmail,
    .oauth_token = [_]u8{0} ** OAUTH_TOKEN_SIZE,
    .oauth_token_len = 0,
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
pub export fn comms_authenticate(provider: c_int) c_int {
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
pub export fn comms_logout(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .unauthenticated)) return -2;

    // Wipe OAuth token on logout
    @memset(&sessions[idx].oauth_token, 0);
    sessions[idx].oauth_token_len = 0;
    sessions[idx].active = false;
    sessions[idx].state = .unauthenticated;
    return 0;
}

/// Begin an operation (transition Authenticated -> Operating).
pub export fn comms_begin_operation(slot_idx: c_int) c_int {
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
pub export fn comms_end_operation(slot_idx: c_int) c_int {
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
pub export fn comms_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(SessionState.unauthenticated);
    return @intFromEnum(sessions[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn comms_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: SessionState = @enumFromInt(from);
    const t: SessionState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sessions (for testing).
pub export fn comms_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        @memset(&slot.oauth_token, 0);
        slot.oauth_token_len = 0;
        slot.active = false;
        slot.state = .unauthenticated;
        slot.result_len = 0;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the comms-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_init() c_int {
    comms_reset();
    return 0;
}

/// Deinitialise the comms-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_deinit() void {
    comms_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "comms-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "comms_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "comms_logout"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "comms_execute"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "comms_state"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Gmail Provider (provider code 1)
// Grade D Alpha — stub implementations
// Real API: https://gmail.googleapis.com/gmail/v1/users/me/{endpoint}
// Auth: Authorization: Bearer {oauth_token}
// ═══════════════════════════════════════════════════════════════════════

/// Validate that a slot is active, authenticated, and bound to the Gmail provider.
fn validateGmailSlot(slot_idx: c_int) ?usize {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return null;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return null;
    if (sessions[idx].provider != .gmail) return null;
    if (sessions[idx].state != .authenticated) return null;
    return idx;
}

/// Write a JSON stub response into a session's result buffer.
fn writeGmailResult(slot: *SessionSlot, endpoint: []const u8, method: []const u8) void {
    const prefix = "{\"provider\":\"gmail\",\"endpoint\":\"";
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

/// Set OAuth credentials on a Gmail session slot.
pub export fn comms_gmail_set_credentials(slot_idx: c_int, token_ptr: [*]const u8, token_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateGmailSlot(slot_idx) orelse return -1;
    if (token_len > OAUTH_TOKEN_SIZE) return -3;
    @memcpy(sessions[idx].oauth_token[0..token_len], token_ptr[0..token_len]);
    sessions[idx].oauth_token_len = token_len;
    return 0;
}

/// Send an email via Gmail. json_ptr/json_len contain the message JSON.
pub export fn comms_gmail_send(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateGmailSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    writeGmailResult(&sessions[idx], "messages/send", "POST");
    return 0;
}

/// Read an email by message ID via Gmail.
pub export fn comms_gmail_read(slot_idx: c_int, msg_id_ptr: [*]const u8, msg_id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateGmailSlot(slot_idx) orelse return -1;
    _ = msg_id_ptr[0..msg_id_len];
    writeGmailResult(&sessions[idx], "messages/{id}", "GET");
    return 0;
}

/// Search emails via Gmail. query_ptr/query_len contain the search query.
pub export fn comms_gmail_search(slot_idx: c_int, query_ptr: [*]const u8, query_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateGmailSlot(slot_idx) orelse return -1;
    _ = query_ptr[0..query_len];
    writeGmailResult(&sessions[idx], "messages?q={query}", "GET");
    return 0;
}

/// List Gmail labels.
pub export fn comms_gmail_labels(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateGmailSlot(slot_idx) orelse return -1;
    writeGmailResult(&sessions[idx], "labels", "GET");
    return 0;
}

/// Read the result buffer for a Gmail session slot. Returns length or -1 on error.
pub export fn comms_gmail_read_result(slot_idx: c_int, out_ptr: [*]u8, out_cap: usize) c_int {
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
// Google Calendar Provider (provider code 2)
// Grade D Alpha — stub implementations
// Real API: https://www.googleapis.com/calendar/v3/{endpoint}
// Auth: Authorization: Bearer {oauth_token}
// ═══════════════════════════════════════════════════════════════════════

/// Validate that a slot is active, authenticated, and bound to the Google Calendar provider.
fn validateCalendarSlot(slot_idx: c_int) ?usize {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return null;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return null;
    if (sessions[idx].provider != .google_calendar) return null;
    if (sessions[idx].state != .authenticated) return null;
    return idx;
}

/// Write a JSON stub response into a session's result buffer for Calendar.
fn writeCalendarResult(slot: *SessionSlot, endpoint: []const u8, method: []const u8) void {
    const prefix = "{\"provider\":\"google_calendar\",\"endpoint\":\"";
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

/// Set OAuth credentials on a Google Calendar session slot.
pub export fn comms_calendar_set_credentials(slot_idx: c_int, token_ptr: [*]const u8, token_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCalendarSlot(slot_idx) orelse return -1;
    if (token_len > OAUTH_TOKEN_SIZE) return -3;
    @memcpy(sessions[idx].oauth_token[0..token_len], token_ptr[0..token_len]);
    sessions[idx].oauth_token_len = token_len;
    return 0;
}

/// List calendar events. json_ptr/json_len contain optional filter JSON.
pub export fn comms_calendar_events(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCalendarSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    writeCalendarResult(&sessions[idx], "calendars/primary/events", "GET");
    return 0;
}

/// Create a calendar event. json_ptr/json_len contain event JSON.
pub export fn comms_calendar_create_event(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCalendarSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    writeCalendarResult(&sessions[idx], "calendars/primary/events", "POST");
    return 0;
}

/// Query free/busy information. json_ptr/json_len contain time range JSON.
pub export fn comms_calendar_free_busy(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCalendarSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    writeCalendarResult(&sessions[idx], "freeBusy", "POST");
    return 0;
}

/// Read the result buffer for a Calendar session slot. Returns length or -1 on error.
pub export fn comms_calendar_read_result(slot_idx: c_int, out_ptr: [*]u8, out_cap: usize) c_int {
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
    comms_reset();
    const slot = comms_authenticate(@intFromEnum(CommsProvider.gmail));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), comms_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), comms_logout(slot));
}

test "cannot operate on unauthenticated" {
    comms_reset();
    const slot = comms_authenticate(@intFromEnum(CommsProvider.gmail));
    _ = comms_logout(slot);
    // Should fail — can't begin operation on unauthenticated session
    try std.testing.expectEqual(@as(c_int, -1), comms_begin_operation(slot));
}

test "operation lifecycle" {
    comms_reset();
    const slot = comms_authenticate(@intFromEnum(CommsProvider.gmail));
    try std.testing.expectEqual(@as(c_int, 0), comms_begin_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.operating)), comms_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), comms_end_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), comms_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), comms_logout(slot));
}

test "cannot double-logout" {
    comms_reset();
    const slot = comms_authenticate(@intFromEnum(CommsProvider.google_calendar));
    _ = comms_logout(slot);
    // Second logout should fail — already unauthenticated
    try std.testing.expectEqual(@as(c_int, -1), comms_logout(slot));
}

test "cannot logout while operating" {
    comms_reset();
    const slot = comms_authenticate(@intFromEnum(CommsProvider.gmail));
    _ = comms_begin_operation(slot);
    // Cannot logout directly from operating — must end operation first
    try std.testing.expectEqual(@as(c_int, -2), comms_logout(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), comms_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), comms_can_transition(1, 2)); // auth -> operating
    try std.testing.expectEqual(@as(c_int, 1), comms_can_transition(2, 1)); // operating -> auth
    try std.testing.expectEqual(@as(c_int, 1), comms_can_transition(1, 0)); // auth -> unauth
    try std.testing.expectEqual(@as(c_int, 1), comms_can_transition(2, 3)); // operating -> error
    try std.testing.expectEqual(@as(c_int, 1), comms_can_transition(3, 0)); // error -> unauth
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), comms_can_transition(0, 2)); // unauth -> operating
    try std.testing.expectEqual(@as(c_int, 0), comms_can_transition(2, 0)); // operating -> unauth
}

test "max sessions enforced" {
    comms_reset();
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = comms_authenticate(@intFromEnum(CommsProvider.gmail));
        try std.testing.expect(s.* >= 0);
    }
    // Next authenticate should fail
    try std.testing.expectEqual(@as(c_int, -1), comms_authenticate(@intFromEnum(CommsProvider.gmail)));
    // Free one and retry
    _ = comms_logout(slots[0]);
    try std.testing.expect(comms_authenticate(@intFromEnum(CommsProvider.gmail)) >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// Gmail Provider Tests
// ═══════════════════════════════════════════════════════════════════════

test "gmail auth and credential storage" {
    comms_reset();
    const slot = comms_authenticate(@intFromEnum(CommsProvider.gmail));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), comms_state(slot));
    // Set OAuth credentials
    const token = "ya29.test_oauth_token_gmail_abc123";
    try std.testing.expectEqual(@as(c_int, 0), comms_gmail_set_credentials(slot, token.ptr, token.len));
    try std.testing.expectEqual(@as(c_int, 0), comms_logout(slot));
}

test "gmail send and search" {
    comms_reset();
    const slot = comms_authenticate(@intFromEnum(CommsProvider.gmail));
    try std.testing.expect(slot >= 0);
    // Send email
    const email_json = "{\"to\":\"test@example.com\",\"subject\":\"Test\",\"body\":\"Hello\"}";
    try std.testing.expectEqual(@as(c_int, 0), comms_gmail_send(slot, email_json.ptr, email_json.len));
    // Read result
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    const len = comms_gmail_read_result(slot, &buf, buf.len);
    try std.testing.expect(len > 0);
    const result = buf[0..@intCast(len)];
    try std.testing.expect(std.mem.indexOf(u8, result, "\"provider\":\"gmail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"endpoint\":\"messages/send\"") != null);
    // Search
    const query = "from:sender@example.com";
    try std.testing.expectEqual(@as(c_int, 0), comms_gmail_search(slot, query.ptr, query.len));
    // Read message
    const msg_id = "msg_abc123";
    try std.testing.expectEqual(@as(c_int, 0), comms_gmail_read(slot, msg_id.ptr, msg_id.len));
    // Labels
    try std.testing.expectEqual(@as(c_int, 0), comms_gmail_labels(slot));
    _ = comms_logout(slot);
}

// ═══════════════════════════════════════════════════════════════════════
// Google Calendar Provider Tests
// ═══════════════════════════════════════════════════════════════════════

test "calendar auth and events" {
    comms_reset();
    const slot = comms_authenticate(@intFromEnum(CommsProvider.google_calendar));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), comms_state(slot));
    // Set OAuth credentials
    const token = "ya29.test_oauth_token_calendar_xyz";
    try std.testing.expectEqual(@as(c_int, 0), comms_calendar_set_credentials(slot, token.ptr, token.len));
    // List events
    const filter = "{\"timeMin\":\"2026-01-01T00:00:00Z\"}";
    try std.testing.expectEqual(@as(c_int, 0), comms_calendar_events(slot, filter.ptr, filter.len));
    // Read result
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    const len = comms_calendar_read_result(slot, &buf, buf.len);
    try std.testing.expect(len > 0);
    const result = buf[0..@intCast(len)];
    try std.testing.expect(std.mem.indexOf(u8, result, "\"provider\":\"google_calendar\"") != null);
    // Create event
    const event_json = "{\"summary\":\"Meeting\",\"start\":\"2026-03-15T10:00:00Z\"}";
    try std.testing.expectEqual(@as(c_int, 0), comms_calendar_create_event(slot, event_json.ptr, event_json.len));
    // Free/busy
    const range_json = "{\"timeMin\":\"2026-03-15T00:00:00Z\",\"timeMax\":\"2026-03-16T00:00:00Z\"}";
    try std.testing.expectEqual(@as(c_int, 0), comms_calendar_free_busy(slot, range_json.ptr, range_json.len));
    _ = comms_logout(slot);
}

test "cross-provider rejection gmail on calendar slot" {
    comms_reset();
    // Authenticate as Google Calendar, then try Gmail operations — should fail
    const slot = comms_authenticate(@intFromEnum(CommsProvider.google_calendar));
    try std.testing.expect(slot >= 0);
    // All Gmail operations should return -1 (wrong provider)
    const email_json = "{\"to\":\"test@example.com\"}";
    try std.testing.expectEqual(@as(c_int, -1), comms_gmail_send(slot, email_json.ptr, email_json.len));
    try std.testing.expectEqual(@as(c_int, -1), comms_gmail_read(slot, email_json.ptr, email_json.len));
    try std.testing.expectEqual(@as(c_int, -1), comms_gmail_search(slot, email_json.ptr, email_json.len));
    try std.testing.expectEqual(@as(c_int, -1), comms_gmail_labels(slot));
    const token = "ya29.test";
    try std.testing.expectEqual(@as(c_int, -1), comms_gmail_set_credentials(slot, token.ptr, token.len));
    _ = comms_logout(slot);
}

test "cross-provider rejection calendar on gmail slot" {
    comms_reset();
    // Authenticate as Gmail, then try Calendar operations — should fail
    const slot = comms_authenticate(@intFromEnum(CommsProvider.gmail));
    try std.testing.expect(slot >= 0);
    // All Calendar operations should return -1 (wrong provider)
    const json_data = "{}";
    try std.testing.expectEqual(@as(c_int, -1), comms_calendar_events(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), comms_calendar_create_event(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), comms_calendar_free_busy(slot, json_data.ptr, json_data.len));
    const token = "ya29.test";
    try std.testing.expectEqual(@as(c_int, -1), comms_calendar_set_credentials(slot, token.ptr, token.len));
    _ = comms_logout(slot);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "comms_authenticate",
        "comms_logout",
        "comms_execute",
        "comms_state",
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
    const rc = boj_cartridge_invoke("comms_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
