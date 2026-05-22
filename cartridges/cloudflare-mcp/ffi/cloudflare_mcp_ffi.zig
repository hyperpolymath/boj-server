// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// cloudflare_mcp_ffi.zig -- C-ABI FFI for cloudflare-mcp cartridge.
//
// Implements the state machine defined in CloudflareMcp.SafeCloud (Idris2 ABI).
// Auth: Bearer token (CF_API_TOKEN). Thread-safe via std.Thread.Mutex.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI)
// ---------------------------------------------------------------------------

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated   = 1,
    rate_limited    = 2,
    err             = 3,
};

pub const CloudflareAction = enum(c_int) {
    list_zones          = 0,
    get_zone            = 1,
    list_dns_records    = 2,
    get_dns_record      = 3,
    create_dns_record   = 4,
    update_dns_record   = 5,
    patch_dns_record    = 6,
    delete_dns_record   = 7,
    get_zone_setting    = 8,
    update_zone_setting = 9,
    purge_cache         = 10,
};

fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated or to == .err,
        .authenticated   => to == .rate_limited or to == .err or to == .unauthenticated,
        .rate_limited    => to == .authenticated or to == .err,
        .err             => to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// Session pool (thread-safe, fixed-size)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const TOKEN_BUF_SIZE: usize = 512;

const SessionSlot = struct {
    active: bool = false,
    state:  SessionState = .unauthenticated,
    token:  [TOKEN_BUF_SIZE]u8 = std.mem.zeroes([TOKEN_BUF_SIZE]u8),
    token_len: usize = 0,
};

var session_pool: [MAX_SESSIONS]SessionSlot = undefined;
var pool_mutex: std.Thread.Mutex = .{};
var pool_initialised: bool = false;

fn initPool() void {
    if (pool_initialised) return;
    for (&session_pool) |*slot| slot.* = SessionSlot{};
    pool_initialised = true;
}

// ---------------------------------------------------------------------------
// Exported C ABI functions
// ---------------------------------------------------------------------------

/// Allocate a session slot and store the API token.
/// Returns slot index (0-based) or -1 on failure.
export fn cf_session_create(token_ptr: [*c]const u8, token_len: usize) c_int {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    initPool();

    if (token_len == 0 or token_len >= TOKEN_BUF_SIZE) return -1;

    for (&session_pool, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state  = .authenticated;
            slot.token_len = token_len;
            @memcpy(slot.token[0..token_len], token_ptr[0..token_len]);
            return @intCast(i);
        }
    }
    return -1;
}

/// Return the current state of a session slot.
export fn cf_session_state(slot_index: c_int) c_int {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    const i: usize = @intCast(slot_index);
    if (i >= MAX_SESSIONS or !session_pool[i].active) return @intFromEnum(SessionState.err);
    return @intFromEnum(session_pool[i].state);
}

/// Transition a session to a new state (validates transition before applying).
export fn cf_session_transition(slot_index: c_int, new_state: c_int) c_int {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    const i: usize = @intCast(slot_index);
    if (i >= MAX_SESSIONS or !session_pool[i].active) return -1;

    const from = session_pool[i].state;
    const to: SessionState = @enumFromInt(new_state);

    if (!isValidTransition(from, to)) return -1;
    session_pool[i].state = to;
    return 0;
}

/// Release a session slot.
export fn cf_session_destroy(slot_index: c_int) void {
    pool_mutex.lock();
    defer pool_mutex.unlock();

    const i: usize = @intCast(slot_index);
    if (i < MAX_SESSIONS) session_pool[i] = SessionSlot{};
}

/// Check whether a DNS record type supports Cloudflare proxying.
/// Returns 1 if proxyable (A=1, AAAA=2, CNAME=3), 0 otherwise.
export fn cf_record_type_is_proxyable(record_type_int: c_int) c_int {
    return if (record_type_int >= 1 and record_type_int <= 3) 1 else 0;
}

/// Check whether a proxied record provides IPv6 (always true when proxied).
export fn cf_proxied_provides_ipv6(proxied: c_int) c_int {
    return if (proxied != 0) 1 else 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "cloudflare-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "cf_list_zones"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_get_zone"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_list_dns_records"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_get_dns_record"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_create_dns_record"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_update_dns_record"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_patch_dns_record"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_delete_dns_record"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_get_zone_setting"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_update_zone_setting"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cf_purge_cache"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns cloudflare-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("cloudflare-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "cf_list_zones",
        "cf_get_zone",
        "cf_list_dns_records",
        "cf_get_dns_record",
        "cf_create_dns_record",
        "cf_update_dns_record",
        "cf_patch_dns_record",
        "cf_delete_dns_record",
        "cf_get_zone_setting",
        "cf_update_zone_setting",
        "cf_purge_cache",
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
    const rc = boj_cartridge_invoke("cf_list_zones", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
