// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// npm_registry_mcp_ffi.zig — C-ABI FFI implementation for npm-registry-mcp cartridge.
//
// Implements the state machine defined in NpmRegistryMcp.SafeRegistry (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: Optional Bearer token — most npm registry reads are public.
// REST API: https://registry.npmjs.org
// Actions: SearchPackages, GetPackage, GetPackageVersion, ListVersions,
//          GetDownloads, GetDownloadsRange, GetDependencies, GetMaintainers,
//          GetDistTags, GetAuditAdvisories, GetProvenance, GetPackument
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session authentication/lifecycle state.
/// 0 = Unauthenticated, 1 = Authenticated, 2 = RateLimited, 3 = Error.
pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// npm registry action identifiers matching Idris2 NpmAction encoding.
pub const NpmAction = enum(c_int) {
    search_packages = 0,
    get_package = 1,
    get_package_version = 2,
    list_versions = 3,
    get_downloads = 4,
    get_downloads_range = 5,
    get_dependencies = 6,
    get_maintainers = 7,
    get_dist_tags = 8,
    get_audit_advisories = 9,
    get_provenance = 10,
    get_packument = 11,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
/// npm registry allows both authenticated and unauthenticated sessions,
/// so transitions are more flexible than services requiring auth.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated or to == .rate_limited or to == .err,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated or to == .unauthenticated,
        .err => to == .authenticated or to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
    search_count: u32 = 0,
    package_count: u32 = 0,
    download_queries: u32 = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn npm_registry_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open an authenticated session. Returns slot index (>= 0) or error (< 0).
/// Error codes: -1 = no free slots.
pub export fn npm_registry_mcp_authenticate(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.search_count = 0;
            slot.package_count = 0;
            slot.download_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Open an unauthenticated session (read-only public access).
/// Returns slot index (>= 0) or error (< 0).
pub export fn npm_registry_mcp_open_anonymous(dummy: c_int) c_int {
    _ = dummy;
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .unauthenticated;
            slot.api_call_count = 0;
            slot.last_action = -1;
            slot.search_count = 0;
            slot.package_count = 0;
            slot.download_queries = 0;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success.
/// Error codes: -1 = invalid slot.
pub export fn npm_registry_mcp_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    sessions[idx] = SessionSlot{};
    return 0;
}

/// Get current state of a session. Returns state int or -1 if invalid.
pub export fn npm_registry_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn npm_registry_mcp_throttle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .rate_limited)) return -2;

    sessions[idx].state = .rate_limited;
    return 0;
}

/// Clear rate limiting. Returns 0 on success.
pub export fn npm_registry_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated) and !isValidTransition(slot.state, .unauthenticated)) return -2;

    // Restore to previous meaningful state (authenticated if was authed)
    sessions[idx].state = .authenticated;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn npm_registry_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    sessions[idx].state = .err;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — action recording and metrics
// ---------------------------------------------------------------------------

/// Record an API call on a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = rate limited, -3 = invalid action.
pub export fn npm_registry_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    const act = std.meta.intToEnum(NpmAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state == .rate_limited) return -2;
    if (slot.state == .err) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;

    // Track category-specific counts
    switch (act) {
        .search_packages => sessions[idx].search_count += 1,
        .get_package, .get_package_version, .get_packument => sessions[idx].package_count += 1,
        .get_downloads, .get_downloads_range => sessions[idx].download_queries += 1,
        else => {},
    }

    return 0;
}

/// Get API call count for a session. Returns count or -1 if invalid.
pub export fn npm_registry_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get search query count. Returns count or -1 if invalid.
pub export fn npm_registry_mcp_search_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.search_count);
}

/// Get package metadata query count. Returns count or -1 if invalid.
pub export fn npm_registry_mcp_package_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.package_count);
}

/// Get download statistics query count. Returns count or -1 if invalid.
pub export fn npm_registry_mcp_download_query_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.download_queries);
}

/// Get total action count. Always returns 12.
pub export fn npm_registry_mcp_action_count() c_int {
    return 12;
}

/// Reset all sessions (test/debug use only).
pub export fn npm_registry_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "npm-registry-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "npm_search_packages"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_package"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_package_version"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_list_versions"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_downloads"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_downloads_range"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_dependencies"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_maintainers"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_dist_tags"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_audit_advisories"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_provenance"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "npm_get_packument"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "authenticated session lifecycle" {
    npm_registry_mcp_reset();

    const slot = npm_registry_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // Should be authenticated (1)
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_session_state(slot));

    // Record a search call (action 0)
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_search_count(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_close(slot));
}

test "anonymous session lifecycle" {
    npm_registry_mcp_reset();

    const slot = npm_registry_mcp_open_anonymous(0);
    try std.testing.expect(slot >= 0);

    // Should be unauthenticated (0)
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_session_state(slot));

    // Record a package lookup (action 1)
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_record_call(slot, 1));
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_package_count(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_close(slot));
}

test "rate limiting flow" {
    npm_registry_mcp_reset();

    const slot = npm_registry_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // Throttle
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), npm_registry_mcp_session_state(slot));

    // Cannot invoke while rate limited
    try std.testing.expectEqual(@as(c_int, -2), npm_registry_mcp_record_call(slot, 0));

    // Unthrottle
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_session_state(slot));
}

test "error and recovery" {
    npm_registry_mcp_reset();

    const slot = npm_registry_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), npm_registry_mcp_session_state(slot));

    // Cannot invoke in error state
    try std.testing.expectEqual(@as(c_int, -2), npm_registry_mcp_record_call(slot, 0));

    // Close (recover)
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_close(slot));
}

test "category counting" {
    npm_registry_mcp_reset();

    const slot = npm_registry_mcp_authenticate(0);
    try std.testing.expect(slot >= 0);

    // Search (0)
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_record_call(slot, 0));
    // GetPackage (1)
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_record_call(slot, 1));
    // GetDownloads (4)
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_record_call(slot, 4));
    // GetDownloadsRange (5)
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_record_call(slot, 5));

    try std.testing.expectEqual(@as(c_int, 4), npm_registry_mcp_call_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_search_count(slot));
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_package_count(slot));
    try std.testing.expectEqual(@as(c_int, 2), npm_registry_mcp_download_query_count(slot));
}

test "transition validator" {
    // Unauthenticated -> Authenticated
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_can_transition(0, 1));
    // Authenticated -> Unauthenticated
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_can_transition(1, 0));
    // Authenticated -> RateLimited
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_can_transition(1, 2));
    // Unauthenticated -> RateLimited
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_can_transition(0, 2));
    // RateLimited -> Authenticated
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_can_transition(2, 1));
    // Error -> Unauthenticated
    try std.testing.expectEqual(@as(c_int, 1), npm_registry_mcp_can_transition(3, 0));

    // Invalid: RateLimited -> Error
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_can_transition(2, 3));
    // Invalid: RateLimited -> RateLimited
    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_can_transition(2, 2));
}

test "slot exhaustion" {
    npm_registry_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = npm_registry_mcp_authenticate(0);
        try std.testing.expect(s.* >= 0);
    }

    try std.testing.expectEqual(@as(c_int, -1), npm_registry_mcp_authenticate(0));

    try std.testing.expectEqual(@as(c_int, 0), npm_registry_mcp_close(slots[0]));
    const new_slot = npm_registry_mcp_authenticate(0);
    try std.testing.expect(new_slot >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns npm-registry-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("npm-registry-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "npm_search_packages",
        "npm_get_package",
        "npm_get_package_version",
        "npm_list_versions",
        "npm_get_downloads",
        "npm_get_downloads_range",
        "npm_get_dependencies",
        "npm_get_maintainers",
        "npm_get_dist_tags",
        "npm_get_audit_advisories",
        "npm_get_provenance",
        "npm_get_packument",
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
    const rc = boj_cartridge_invoke("npm_search_packages", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
