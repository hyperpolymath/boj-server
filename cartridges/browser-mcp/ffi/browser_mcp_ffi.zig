// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// browser_mcp_ffi.zig — C-ABI FFI implementation for browser-mcp cartridge.
//
// Implements the browser state machine defined in the Idris2 ABI layer
// for Firefox automation via the Marionette protocol (TCP localhost:2828).
// Thread-safe via std.Thread.Mutex. No heap allocations for results.

const std = @import("std");

// ---------------------------------------------------------------------------
// Browser state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// Connection state for the Marionette protocol session.
pub const BrowserState = enum(c_int) {
    closed = 0,
    connecting = 1,
    connected = 2,
    navigating = 3,
    err = 4,
};

/// Browser actions that can be performed via Marionette.
pub const BrowserAction = enum(c_int) {
    navigate = 0,
    click = 1,
    type_text = 2,
    screenshot = 3,
    read_page = 4,
    fill_form = 5,
    execute_js = 6,
    tab_create = 7,
    tab_close = 8,
    tab_list = 9,
};

/// Check if a browser state transition is valid.
fn isValidTransition(from: BrowserState, to: BrowserState) bool {
    return switch (from) {
        .closed => to == .connecting,
        .connecting => to == .connected or to == .err,
        .connected => to == .navigating or to == .closed or to == .err,
        .navigating => to == .connected or to == .err,
        .err => to == .closed,
    };
}

// ---------------------------------------------------------------------------
// Browser session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const URL_BUF_SIZE: usize = 4096;
const TITLE_BUF_SIZE: usize = 1024;
const RESULT_BUF_SIZE: usize = 65536;

/// Represents a single browser tab handle.
const TabHandle = struct {
    active: bool = false,
    id: u32 = 0,
    url_buf: [URL_BUF_SIZE]u8 = undefined,
    url_len: usize = 0,
    title_buf: [TITLE_BUF_SIZE]u8 = undefined,
    title_len: usize = 0,
};

const MAX_TABS: usize = 64;

/// A browser session slot managing connection state, tabs, and result buffers.
const BrowserSession = struct {
    active: bool = false,
    state: BrowserState = .closed,
    // Marionette connection target
    marionette_port: u16 = 2828,
    // Current page state
    current_url_buf: [URL_BUF_SIZE]u8 = undefined,
    current_url_len: usize = 0,
    page_title_buf: [TITLE_BUF_SIZE]u8 = undefined,
    page_title_len: usize = 0,
    load_complete: bool = false,
    // Tab tracking
    tabs: [MAX_TABS]TabHandle = [_]TabHandle{.{}} ** MAX_TABS,
    tab_count: usize = 0,
    // Result buffer (for screenshot, read_page, tab_list, execute_js)
    result_buf: [RESULT_BUF_SIZE]u8 = undefined,
    result_len: usize = 0,
};

var sessions: [MAX_SESSIONS]BrowserSession = [_]BrowserSession{.{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Attempt a state transition on a session. Returns 0 on success, -2 on invalid.
fn transitionState(slot: *BrowserSession, to: BrowserState) c_int {
    if (!isValidTransition(slot.state, to)) return -2;
    slot.state = to;
    return 0;
}

/// Validate a slot index and return a pointer, or null if invalid/inactive.
fn getActiveSlot(slot_idx: c_int) ?*BrowserSession {
    const idx: usize = std.math.cast(usize, slot_idx) orelse return null;
    if (idx >= MAX_SESSIONS) return null;
    const slot = &sessions[idx];
    if (!slot.active) return null;
    return slot;
}

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a browser state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn browser_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(BrowserState, from) catch return 0;
    const t = std.meta.intToEnum(BrowserState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — session management
// ---------------------------------------------------------------------------

/// Open a new browser session. Returns slot index (>= 0) or -1 if no free slots.
pub export fn browser_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.* = .{};
            slot.active = true;
            slot.state = .closed;
            return @intCast(idx);
        }
    }
    return -1; // No free slots
}

/// Close a browser session. Returns 0 on success, -1 if slot invalid.
pub export fn browser_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    slot.* = .{};
    return 0;
}

/// Get the current state of a browser session. Returns state int or -1 if invalid.
pub export fn browser_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    return @intFromEnum(slot.state);
}

/// Reset all sessions (test/debug use only).
pub export fn browser_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]BrowserSession{.{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// C-ABI exports — Marionette connection lifecycle
// ---------------------------------------------------------------------------

/// Initiate connection to Firefox Marionette (Closed -> Connecting).
/// Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn browser_mcp_connect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    const rc = transitionState(slot, .connecting);
    if (rc != 0) return rc;
    // In a real implementation, this would initiate TCP to localhost:2828.
    // Immediately transition to connected for the state machine layer.
    slot.state = .connected;
    return 0;
}

/// Disconnect from Firefox Marionette (Connected -> Closed).
/// Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn browser_mcp_disconnect(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    return transitionState(slot, .closed);
}

// ---------------------------------------------------------------------------
// C-ABI exports — browser actions
// ---------------------------------------------------------------------------

/// Navigate to a URL. Writes url into the session's current_url buffer.
/// Returns 0 on success, -1 if invalid slot, -2 if not connected, -3 if URL too long.
pub export fn browser_mcp_navigate(slot_idx: c_int, url_ptr: [*]const u8, url_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const len: usize = std.math.cast(usize, url_len) orelse return -3;
    if (len > URL_BUF_SIZE) return -3;

    // Transition: Connected -> Navigating -> Connected
    slot.state = .navigating;
    @memcpy(slot.current_url_buf[0..len], url_ptr[0..len]);
    slot.current_url_len = len;
    slot.load_complete = true;
    slot.state = .connected;
    return 0;
}

/// Click an element by CSS selector.
/// Returns 0 on success, -1 if invalid slot, -2 if not connected.
pub export fn browser_mcp_click(slot_idx: c_int, selector_ptr: [*]const u8, selector_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    // Validate selector length
    const len: usize = std.math.cast(usize, selector_len) orelse return -3;
    if (len == 0) return -3;

    // In real implementation: send Marionette findElement + clickElement commands
    _ = selector_ptr;
    return 0;
}

/// Type text into an element matching a CSS selector.
/// Returns 0 on success, -1 if invalid slot, -2 if not connected.
pub export fn browser_mcp_type(slot_idx: c_int, selector_ptr: [*]const u8, selector_len: c_int, text_ptr: [*]const u8, text_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const sel_len: usize = std.math.cast(usize, selector_len) orelse return -3;
    const txt_len: usize = std.math.cast(usize, text_len) orelse return -3;
    if (sel_len == 0 or txt_len == 0) return -3;

    // In real implementation: send Marionette findElement + sendKeys commands
    _ = selector_ptr;
    _ = text_ptr;
    return 0;
}

/// Capture a screenshot. Writes PNG data into the session's result_buf.
/// Returns bytes written on success (>= 0), -1 if invalid slot, -2 if not connected.
pub export fn browser_mcp_screenshot(slot_idx: c_int, out_buf: [*]u8, out_buf_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const buf_len: usize = std.math.cast(usize, out_buf_len) orelse return -3;

    // In real implementation: send Marionette takeScreenshot command
    // For now, write a placeholder indicating the operation was invoked
    const placeholder = "SCREENSHOT_PLACEHOLDER";
    if (buf_len < placeholder.len) return -3;
    @memcpy(out_buf[0..placeholder.len], placeholder);
    return @intCast(placeholder.len);
}

/// Read the current page DOM text. Writes text into out_buf.
/// Returns bytes written on success (>= 0), -1 if invalid slot, -2 if not connected.
pub export fn browser_mcp_read_page(slot_idx: c_int, out_buf: [*]u8, out_buf_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const buf_len: usize = std.math.cast(usize, out_buf_len) orelse return -3;

    // In real implementation: send Marionette getPageSource or executeScript
    // Return current URL as proof the session is tracking state
    if (slot.current_url_len == 0) {
        const empty = "NO_PAGE_LOADED";
        if (buf_len < empty.len) return -3;
        @memcpy(out_buf[0..empty.len], empty);
        return @intCast(empty.len);
    }
    if (buf_len < slot.current_url_len) return -3;
    @memcpy(out_buf[0..slot.current_url_len], slot.current_url_buf[0..slot.current_url_len]);
    return @intCast(slot.current_url_len);
}

// ---------------------------------------------------------------------------
// C-ABI exports — tab management
// ---------------------------------------------------------------------------

/// Create a new tab. Returns tab index (>= 0) or error code (< 0).
/// -1 = invalid slot, -2 = not connected, -3 = tab limit reached.
pub export fn browser_mcp_tab_create(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;
    if (slot.tab_count >= MAX_TABS) return -3;

    const tab_idx = slot.tab_count;
    slot.tabs[tab_idx] = .{
        .active = true,
        .id = @intCast(tab_idx),
    };
    slot.tab_count += 1;

    // In real implementation: send Marionette newWindow command
    return @intCast(tab_idx);
}

/// Close a tab by index. Returns 0 on success, -1 if invalid slot,
/// -2 if not connected, -3 if tab index invalid.
pub export fn browser_mcp_tab_close(slot_idx: c_int, tab_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const tidx: usize = std.math.cast(usize, tab_idx) orelse return -3;
    if (tidx >= slot.tab_count) return -3;
    if (!slot.tabs[tidx].active) return -3;

    slot.tabs[tidx].active = false;

    // In real implementation: send Marionette closeWindow command
    return 0;
}

/// List open tabs. Writes tab count to out_buf as a simple integer string.
/// Returns bytes written on success (>= 0), or error code (< 0).
pub export fn browser_mcp_tab_list(slot_idx: c_int, out_buf: [*]u8, out_buf_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    if (slot.state != .connected) return -2;

    const buf_len: usize = std.math.cast(usize, out_buf_len) orelse return -3;

    // Count active tabs
    var active_count: usize = 0;
    for (slot.tabs[0..slot.tab_count]) |tab| {
        if (tab.active) active_count += 1;
    }

    // Write count as ASCII digits
    var tmp_buf: [32]u8 = undefined;
    const result = std.fmt.bufPrint(&tmp_buf, "{d}", .{active_count}) catch return -3;
    if (buf_len < result.len) return -3;
    @memcpy(out_buf[0..result.len], result);
    return @intCast(result.len);
}

/// Signal an error on a session (Connected|Navigating -> Error).
/// Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn browser_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    return transitionState(slot, .err);
}

/// Recover from error (Error -> Closed). Returns 0 on success.
pub export fn browser_mcp_error_recover(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getActiveSlot(slot_idx) orelse return -1;
    return transitionState(slot, .closed);
}

// ---------------------------------------------------------------------------
// Tests — state machine validation (no actual Firefox connections)
// ---------------------------------------------------------------------------

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "browser-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "browser_open"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "browser_close"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "browser_connect"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "browser_navigate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "browser_click"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "browser_type"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "browser_screenshot"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "browser_read_page"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "browser_tab_list"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

test "browser session lifecycle: open -> connect -> disconnect -> close" {
    browser_mcp_reset();

    // Open a session (starts in Closed state)
    const slot = browser_mcp_session_open();
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_session_state(slot)); // closed = 0

    // Connect (Closed -> Connected)
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_connect(slot));
    try std.testing.expectEqual(@as(c_int, 2), browser_mcp_session_state(slot)); // connected = 2

    // Disconnect (Connected -> Closed)
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_disconnect(slot));
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_session_state(slot)); // closed = 0

    // Close the session
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_session_close(slot));
}

test "navigate updates current URL" {
    browser_mcp_reset();

    const slot = browser_mcp_session_open();
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_connect(slot));

    // Navigate
    const url = "https://example.com";
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_navigate(slot, url.ptr, @intCast(url.len)));

    // State should still be connected (navigation completed synchronously)
    try std.testing.expectEqual(@as(c_int, 2), browser_mcp_session_state(slot));

    // Read page should return the URL we navigated to
    var buf: [4096]u8 = undefined;
    const read_len = browser_mcp_read_page(slot, &buf, 4096);
    try std.testing.expect(read_len > 0);
    const read_len_usize: usize = @intCast(read_len);
    try std.testing.expectEqualStrings(url, buf[0..read_len_usize]);
}

test "actions rejected when not connected" {
    browser_mcp_reset();

    const slot = browser_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Session is in Closed state — all actions should fail with -2
    const url = "https://example.com";
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_navigate(slot, url.ptr, @intCast(url.len)));

    const sel = "#btn";
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_click(slot, sel.ptr, @intCast(sel.len)));

    var buf: [128]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_screenshot(slot, &buf, 128));
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_read_page(slot, &buf, 128));
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_tab_create(slot));
}

test "tab management" {
    browser_mcp_reset();

    const slot = browser_mcp_session_open();
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_connect(slot));

    // Create tabs
    const tab0 = browser_mcp_tab_create(slot);
    try std.testing.expect(tab0 >= 0);
    const tab1 = browser_mcp_tab_create(slot);
    try std.testing.expect(tab1 >= 0);

    // List should show 2 active tabs
    var buf: [64]u8 = undefined;
    const list_len = browser_mcp_tab_list(slot, &buf, 64);
    try std.testing.expect(list_len > 0);
    const list_len_usize: usize = @intCast(list_len);
    try std.testing.expectEqualStrings("2", buf[0..list_len_usize]);

    // Close one tab
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_tab_close(slot, tab0));

    // List should now show 1
    const list_len2 = browser_mcp_tab_list(slot, &buf, 64);
    try std.testing.expect(list_len2 > 0);
    const list_len2_usize: usize = @intCast(list_len2);
    try std.testing.expectEqualStrings("1", buf[0..list_len2_usize]);
}

test "invalid state transitions rejected" {
    browser_mcp_reset();

    const slot = browser_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Can't disconnect from Closed state
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_disconnect(slot));

    // Can't signal error from Closed state
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_signal_error(slot));

    // Connect, then try invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_connect(slot));

    // Can't connect again from Connected
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_connect(slot));

    // Can't recover from non-Error state
    try std.testing.expectEqual(@as(c_int, -2), browser_mcp_error_recover(slot));
}

test "transition validator covers all valid browser transitions" {
    // Valid transitions (matching Idris2 ABI)
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(0, 1)); // closed -> connecting
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(1, 2)); // connecting -> connected
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(1, 4)); // connecting -> error
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(2, 3)); // connected -> navigating
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(3, 2)); // navigating -> connected
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(3, 4)); // navigating -> error
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(2, 0)); // connected -> closed
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(2, 4)); // connected -> error
    try std.testing.expectEqual(@as(c_int, 1), browser_mcp_can_transition(4, 0)); // error -> closed

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_can_transition(0, 2)); // closed -> connected (skip)
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_can_transition(0, 3)); // closed -> navigating
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_can_transition(4, 2)); // error -> connected
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_can_transition(3, 0)); // navigating -> closed (must go through connected)

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_can_transition(99, 0));
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_can_transition(0, 99));
}

test "slot exhaustion" {
    browser_mcp_reset();

    // Fill all slots
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = browser_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), browser_mcp_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_session_close(slots[0]));
    const new_slot = browser_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}

test "error recovery flow" {
    browser_mcp_reset();

    const slot = browser_mcp_session_open();
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_connect(slot));

    // Signal error (Connected -> Error)
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 4), browser_mcp_session_state(slot)); // error = 4

    // Recover (Error -> Closed)
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_error_recover(slot));
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_session_state(slot)); // closed = 0

    // Can reconnect after recovery
    try std.testing.expectEqual(@as(c_int, 0), browser_mcp_connect(slot));
    try std.testing.expectEqual(@as(c_int, 2), browser_mcp_session_state(slot)); // connected = 2
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns browser-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("browser-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "browser_open",
        "browser_close",
        "browser_connect",
        "browser_navigate",
        "browser_click",
        "browser_type",
        "browser_screenshot",
        "browser_read_page",
        "browser_tab_list",
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
    const rc = boj_cartridge_invoke("browser_open", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
