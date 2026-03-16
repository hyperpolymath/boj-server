// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gitlab_api_mcp_ffi.zig — C-ABI FFI implementation for gitlab-api-mcp cartridge.
//
// Implements the authentication state machine defined in the Idris2 ABI layer
// (GitlabApiMcp.SafeGit). Provides HTTP client stubs for GitLab REST API v4
// and GraphQL, configurable base URL for self-hosted instances, Private-Token
// authentication (token obtained from vault-mcp), and rate-limit tracking.
//
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap
// allocations for results.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI: SafeGit)
// ---------------------------------------------------------------------------

/// Authentication/session state for GitLab API operations.
///   0 = Unauthenticated — no valid token
///   1 = Authenticated   — token set, ready for requests
///   2 = RateLimited     — must back off
///   3 = Error           — unrecoverable until reset
pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// Valid state transitions (mirrors Idris2 ValidTransition):
///   Unauth -> Auth   (authenticate)
///   Auth   -> Rate   (hit rate limit)
///   Rate   -> Auth   (resume after backoff)
///   Auth   -> Error  (request failure)
///   Error  -> Unauth (reset)
///   Auth   -> Unauth (logout)
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .rate_limited or to == .err or to == .unauthenticated,
        .rate_limited => to == .authenticated,
        .err => to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// HTTP method enum (matches Idris2 HttpMethod)
// ---------------------------------------------------------------------------

pub const HttpMethod = enum(c_int) {
    get = 0,
    post = 1,
    put = 2,
    delete = 3,
};

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 8192;
const TOKEN_SIZE: usize = 256;
const URL_SIZE: usize = 512;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,

    /// Private-Token for GitLab authentication (from vault-mcp).
    token_buf: [TOKEN_SIZE]u8 = undefined,
    token_len: usize = 0,

    /// Base URL for the GitLab instance (default: https://gitlab.com).
    base_url_buf: [URL_SIZE]u8 = undefined,
    base_url_len: usize = 0,

    /// API version path segment (default: "v4").
    api_version_buf: [32]u8 = undefined,
    api_version_len: usize = 0,

    /// Rate-limit tracking: remaining requests in current window.
    rate_limit_remaining: i32 = -1,

    /// Rate-limit tracking: epoch seconds when window resets.
    rate_limit_reset: i64 = 0,

    /// Response buffer for last operation.
    response_buf: [BUF_SIZE]u8 = undefined,
    response_len: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Copy a C string (ptr + len) into a fixed buffer. Returns bytes written, or 0
/// if the source is null or exceeds capacity.
fn copyToBuf(dest: []u8, src: [*c]const u8, len: usize) usize {
    if (src == null) return 0;
    if (len > dest.len) return 0;
    @memcpy(dest[0..len], src[0..len]);
    return len;
}

/// Set default instance config on a slot if not already set.
fn ensureDefaults(slot: *SessionSlot) void {
    if (slot.base_url_len == 0) {
        const default_url = "https://gitlab.com";
        @memcpy(slot.base_url_buf[0..default_url.len], default_url);
        slot.base_url_len = default_url.len;
    }
    if (slot.api_version_len == 0) {
        const default_ver = "v4";
        @memcpy(slot.api_version_buf[0..default_ver.len], default_ver);
        slot.api_version_len = default_ver.len;
    }
}

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn gitlab_api_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — session management
// ---------------------------------------------------------------------------

/// Open a new session in Unauthenticated state.
/// Returns slot index (>= 0) or -1 if no free slots.
pub export fn gitlab_api_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.* = .{};
            slot.active = true;
            slot.state = .unauthenticated;
            ensureDefaults(slot);
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session (must be in Authenticated or Unauthenticated state).
/// Returns 0 on success, -1 if slot invalid, -2 if bad transition.
pub export fn gitlab_api_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;

    // Can close from Unauthenticated (already logged out) or Authenticated (implicit logout).
    if (slot.state != .unauthenticated and slot.state != .authenticated) return -2;

    // Zero the token before releasing.
    @memset(&slot.token_buf, 0);
    slot.* = .{};
    return 0;
}

/// Get the current state of a session. Returns state int or -1 if invalid slot.
pub export fn gitlab_api_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

// ---------------------------------------------------------------------------
// C-ABI exports — authentication
// ---------------------------------------------------------------------------

/// Authenticate a session with a Private-Token and optional base URL.
/// Transitions: Unauthenticated -> Authenticated.
///
/// Parameters:
///   slot_idx  — session slot
///   token     — GitLab Private-Token (from vault-mcp)
///   token_len — length of token string
///   base_url  — GitLab instance base URL (NULL for default https://gitlab.com)
///   url_len   — length of base_url (ignored if base_url is NULL)
///
/// Returns 0 on success, -1 invalid slot, -2 bad transition, -3 token too long,
/// -4 URL too long.
pub export fn gitlab_api_mcp_authenticate(
    slot_idx: c_int,
    token: [*c]const u8,
    token_len: c_int,
    base_url: [*c]const u8,
    url_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    const tlen: usize = std.math.cast(usize, token_len) orelse return -3;
    if (tlen == 0 or tlen > TOKEN_SIZE) return -3;

    slot.token_len = copyToBuf(&slot.token_buf, token, tlen);
    if (slot.token_len == 0) return -3;

    // Optional custom base URL for self-hosted instances.
    if (base_url != null and url_len > 0) {
        const ulen: usize = std.math.cast(usize, url_len) orelse return -4;
        if (ulen > URL_SIZE) return -4;
        slot.base_url_len = copyToBuf(&slot.base_url_buf, base_url, ulen);
        if (slot.base_url_len == 0) return -4;
    }

    slot.state = .authenticated;
    slot.rate_limit_remaining = -1;
    slot.rate_limit_reset = 0;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — REST API request
// ---------------------------------------------------------------------------

/// Execute a GitLab REST API request.
/// Transitions: Authenticated -> Authenticated (on success),
///              Authenticated -> RateLimited (on 429),
///              Authenticated -> Error (on failure).
///
/// Parameters:
///   slot_idx — session slot (must be Authenticated)
///   method   — HTTP method (0=GET, 1=POST, 2=PUT, 3=DELETE)
///   path     — API path, e.g. "/projects" (appended to base_url/api/v4)
///   path_len — length of path
///   body     — request body (NULL for GET/DELETE)
///   body_len — length of body
///   out_buf  — caller-owned buffer for response
///   out_cap  — capacity of out_buf
///   out_len  — pointer to write actual response length
///
/// Returns 0 on success, -1 invalid slot, -2 bad state, -3 rate limited,
/// -4 request error, -5 buffer too small.
///
/// NOTE: This is a stub. Real HTTP dispatch will be wired via the adapter
/// layer or a Zig HTTP client in a future iteration.
pub export fn gitlab_api_mcp_request(
    slot_idx: c_int,
    method: c_int,
    path: [*c]const u8,
    path_len: c_int,
    body: [*c]const u8,
    body_len: c_int,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    _ = body;
    _ = body_len;
    _ = method;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    const plen: usize = std.math.cast(usize, path_len) orelse return -4;
    if (path == null or plen == 0) return -4;

    // Stub: echo back the constructed URL as a placeholder response.
    // Format: "STUB <base_url>/api/<version><path>"
    const cap: usize = std.math.cast(usize, out_cap) orelse return -5;

    const prefix = "STUB ";
    const api_seg = "/api/";

    const total_len = prefix.len + slot.base_url_len + api_seg.len + slot.api_version_len + plen;
    if (total_len > cap) return -5;

    var pos: usize = 0;
    @memcpy(out_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(out_buf[pos .. pos + slot.base_url_len], slot.base_url_buf[0..slot.base_url_len]);
    pos += slot.base_url_len;
    @memcpy(out_buf[pos .. pos + api_seg.len], api_seg);
    pos += api_seg.len;
    @memcpy(out_buf[pos .. pos + slot.api_version_len], slot.api_version_buf[0..slot.api_version_len]);
    pos += slot.api_version_len;
    @memcpy(out_buf[pos .. pos + plen], path[0..plen]);
    pos += plen;

    out_len.* = @intCast(pos);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — GraphQL
// ---------------------------------------------------------------------------

/// Execute a GitLab GraphQL query.
/// Endpoint: POST <base_url>/api/graphql
///
/// Parameters:
///   slot_idx      — session slot (must be Authenticated)
///   query         — GraphQL query string
///   query_len     — length of query
///   variables     — JSON variables string (NULL if none)
///   variables_len — length of variables
///   out_buf       — caller-owned buffer for response
///   out_cap       — capacity of out_buf
///   out_len       — pointer to write actual response length
///
/// Returns 0 on success, negative on error (same codes as gitlab_api_mcp_request).
///
/// NOTE: Stub implementation — real HTTP dispatch in a future iteration.
pub export fn gitlab_api_mcp_graphql(
    slot_idx: c_int,
    query: [*c]const u8,
    query_len: c_int,
    variables: [*c]const u8,
    variables_len: c_int,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    _ = variables;
    _ = variables_len;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    const qlen: usize = std.math.cast(usize, query_len) orelse return -4;
    if (query == null or qlen == 0) return -4;

    const cap: usize = std.math.cast(usize, out_cap) orelse return -5;

    // Stub: echo "GRAPHQL_STUB <base_url>/api/graphql <query_len_bytes>"
    const prefix = "GRAPHQL_STUB ";
    const gql_seg = "/api/graphql";

    const total_len = prefix.len + slot.base_url_len + gql_seg.len;
    if (total_len > cap) return -5;

    var pos: usize = 0;
    @memcpy(out_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(out_buf[pos .. pos + slot.base_url_len], slot.base_url_buf[0..slot.base_url_len]);
    pos += slot.base_url_len;
    @memcpy(out_buf[pos .. pos + gql_seg.len], gql_seg);
    pos += gql_seg.len;

    out_len.* = @intCast(pos);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — push mirror
// ---------------------------------------------------------------------------

/// Set up a push mirror for a GitLab project.
/// Calls POST /projects/:id/remote_mirrors under the hood.
///
/// Parameters:
///   slot_idx    — session slot (must be Authenticated)
///   project_id  — GitLab project ID
///   target_url  — mirror target URL (e.g. "https://github.com/org/repo.git")
///   url_len     — length of target_url
///   out_buf     — caller-owned buffer for response
///   out_cap     — capacity of out_buf
///   out_len     — pointer to write actual response length
///
/// Returns 0 on success, negative on error.
///
/// NOTE: Stub implementation.
pub export fn gitlab_api_mcp_setup_mirror(
    slot_idx: c_int,
    project_id: c_int,
    target_url: [*c]const u8,
    url_len: c_int,
    out_buf: [*c]u8,
    out_cap: c_int,
    out_len: *c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    const tlen: usize = std.math.cast(usize, url_len) orelse return -4;
    if (target_url == null or tlen == 0) return -4;

    const cap: usize = std.math.cast(usize, out_cap) orelse return -5;

    // Stub: "MIRROR_STUB project_id=<id> target=<url>"
    const prefix = "MIRROR_STUB project_id=";

    // Format project_id as string.
    var id_buf: [16]u8 = undefined;
    const pid: usize = std.math.cast(usize, project_id) orelse return -4;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{pid}) catch return -4;

    const target_prefix = " target=";
    const total_len = prefix.len + id_str.len + target_prefix.len + tlen;
    if (total_len > cap) return -5;

    var pos: usize = 0;
    @memcpy(out_buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;
    @memcpy(out_buf[pos .. pos + id_str.len], id_str);
    pos += id_str.len;
    @memcpy(out_buf[pos .. pos + target_prefix.len], target_prefix);
    pos += target_prefix.len;
    @memcpy(out_buf[pos .. pos + tlen], target_url[0..tlen]);
    pos += tlen;

    out_len.* = @intCast(pos);
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — rate limit info
// ---------------------------------------------------------------------------

/// Get the rate-limit remaining count for a session.
/// Returns the remaining count, or -1 if unknown / slot invalid.
pub export fn gitlab_api_mcp_rate_limit_remaining(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.rate_limit_remaining);
}

/// Transition a session to RateLimited state (Authenticated -> RateLimited).
/// Returns 0 on success.
pub export fn gitlab_api_mcp_hit_rate_limit(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .rate_limited)) return -2;

    slot.state = .rate_limited;
    slot.rate_limit_remaining = 0;
    return 0;
}

/// Resume from rate-limited state (RateLimited -> Authenticated).
/// Returns 0 on success.
pub export fn gitlab_api_mcp_resume_from_rate_limit(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    slot.state = .authenticated;
    slot.rate_limit_remaining = -1;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — error handling
// ---------------------------------------------------------------------------

/// Signal an error on an authenticated session (Authenticated -> Error).
/// Returns 0 on success.
pub export fn gitlab_api_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    slot.state = .err;
    return 0;
}

/// Reset from error state (Error -> Unauthenticated).
/// Returns 0 on success.
pub export fn gitlab_api_mcp_reset_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .unauthenticated)) return -2;

    @memset(&slot.token_buf, 0);
    slot.token_len = 0;
    slot.state = .unauthenticated;
    return 0;
}

/// Logout (Authenticated -> Unauthenticated). Zeroes the token.
/// Returns 0 on success.
pub export fn gitlab_api_mcp_logout(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    @memset(&slot.token_buf, 0);
    slot.token_len = 0;
    slot.state = .unauthenticated;
    return 0;
}

/// Reset all sessions (test/debug use only).
pub export fn gitlab_api_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        @memset(&slot.token_buf, 0);
    }
    sessions = [_]SessionSlot{.{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "authentication lifecycle" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be unauthenticated
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_state(slot));

    // Authenticate with default gitlab.com
    const token = "glpat-xxxxxxxxxxxxxxxxxxxx";
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_authenticate(
        slot,
        token,
        @intCast(token.len),
        null,
        0,
    ));
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_session_state(slot));

    // Logout
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_logout(slot));
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_state(slot));

    // Close
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_close(slot));
}

test "self-hosted instance" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    const token = "glpat-selfhosted-token";
    const url = "https://git.example.org";
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_authenticate(
        slot,
        token,
        @intCast(token.len),
        url,
        @intCast(url.len),
    ));
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_session_state(slot));

    // Make a stub request and verify URL contains self-hosted domain
    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;
    const path = "/projects";
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_request(
        slot,
        0, // GET
        path,
        @intCast(path.len),
        null,
        0,
        &buf,
        1024,
        &out_len,
    ));
    const response = buf[0..@intCast(out_len)];
    try std.testing.expect(std.mem.indexOf(u8, response, "git.example.org") != null);

    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_close(slot));
}

test "rate limit flow" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    const token = "glpat-ratelimit-test";
    _ = gitlab_api_mcp_authenticate(slot, token, @intCast(token.len), null, 0);

    // Hit rate limit: Auth -> RateLimited
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_hit_rate_limit(slot));
    try std.testing.expectEqual(@as(c_int, 2), gitlab_api_mcp_session_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_rate_limit_remaining(slot));

    // Resume: RateLimited -> Authenticated
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_resume_from_rate_limit(slot));
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_close(slot));
}

test "error flow" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    const token = "glpat-error-test";
    _ = gitlab_api_mcp_authenticate(slot, token, @intCast(token.len), null, 0);

    // Auth -> Error
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), gitlab_api_mcp_session_state(slot));

    // Error -> Unauthenticated
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_reset_error(slot));
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_state(slot));

    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_close(slot));
}

test "graphql stub" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    const token = "glpat-graphql-test";
    _ = gitlab_api_mcp_authenticate(slot, token, @intCast(token.len), null, 0);

    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;
    const query = "{ currentUser { name } }";
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_graphql(
        slot,
        query,
        @intCast(query.len),
        null,
        0,
        &buf,
        1024,
        &out_len,
    ));
    const response = buf[0..@intCast(out_len)];
    try std.testing.expect(std.mem.indexOf(u8, response, "GRAPHQL_STUB") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "gitlab.com") != null);

    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_close(slot));
}

test "mirror stub" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    const token = "glpat-mirror-test";
    _ = gitlab_api_mcp_authenticate(slot, token, @intCast(token.len), null, 0);

    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;
    const target = "https://github.com/org/repo.git";
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_setup_mirror(
        slot,
        42,
        target,
        @intCast(target.len),
        &buf,
        1024,
        &out_len,
    ));
    const response = buf[0..@intCast(out_len)];
    try std.testing.expect(std.mem.indexOf(u8, response, "MIRROR_STUB") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "42") != null);

    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_close(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_can_transition(1, 2)); // auth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_can_transition(2, 1)); // rate_limited -> auth
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_can_transition(1, 3)); // auth -> error
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_can_transition(3, 0)); // error -> unauth
    try std.testing.expectEqual(@as(c_int, 1), gitlab_api_mcp_can_transition(1, 0)); // auth -> unauth (logout)

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_can_transition(0, 2)); // unauth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_can_transition(0, 3)); // unauth -> error
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_can_transition(2, 3)); // rate -> error
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_can_transition(3, 1)); // error -> auth

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_can_transition(99, 0));
}

test "slot exhaustion" {
    gitlab_api_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = gitlab_api_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), gitlab_api_mcp_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_close(slots[0]));
    const new_slot = gitlab_api_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}
