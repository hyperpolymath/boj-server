// SPDX-License-Identifier: PMPL-1.0-or-later
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
