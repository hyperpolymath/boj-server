// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gitlab_api_mcp_ffi.zig — C-ABI FFI implementation for gitlab-api-mcp cartridge.
//
// Implements the authentication state machine defined in the Idris2 ABI layer
// (GitlabApiMcp.SafeGit). Provides real HTTP dispatch to GitLab REST API v4
// and GraphQL via std.http.Client, configurable base URL for self-hosted
// instances, Private-Token authentication (token obtained from vault-mcp),
// and rate-limit tracking.
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
// GitLab actions (matches Idris2 GitLabAction + actionToInt encoding)
// ---------------------------------------------------------------------------

/// All GitLab REST/GraphQL actions exposed by this cartridge.
/// Encoding mirrors `GitlabApiMcp.SafeGit.actionToInt` (0–19).
/// Declared here so `iseriser abi-verify` can structurally check the
/// encoding against the Idris2 source; dispatch wiring follows the
/// same numbering when introduced.
pub const GitLabAction = enum(c_int) {
    list_projects = 0,
    get_project = 1,
    create_issue = 2,
    list_issues = 3,
    get_issue = 4,
    comment_issue = 5,
    create_mr = 6,
    list_mrs = 7,
    get_mr = 8,
    merge_mr = 9,
    list_branches = 10,
    create_branch = 11,
    search_code = 12,
    list_pipelines = 13,
    get_pipeline = 14,
    trigger_pipeline = 15,
    list_releases = 16,
    create_release = 17,
    push_mirror = 18,
    get_file_contents = 19,
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
/// HTTP dispatch is performed via std.http.Client to <base_url>/api/<version><path>
/// with Private-Token authentication header.
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
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    const plen: usize = std.math.cast(usize, path_len) orelse return -4;
    if (path == null or plen == 0) return -4;

    // Build full URL: <base_url>/api/<version><path>
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const base_url = slot.base_url_buf[0..slot.base_url_len];
    const api_version = slot.api_version_buf[0..slot.api_version_len];
    const path_slice = path[0..plen];
    const url_str = std.fmt.allocPrint(allocator, "{s}/api/{s}{s}", .{ base_url, api_version, path_slice }) catch return -4;

    // Determine HTTP method
    const http_method_enum = std.meta.intToEnum(HttpMethod, method) catch return -4;
    const http_method: std.http.Method = switch (http_method_enum) {
        .get => .GET,
        .post => .POST,
        .put => .PUT,
        .delete => .DELETE,
    };

    // Build auth header: Private-Token
    const auth_header = std.fmt.allocPrint(allocator, "{s}", .{slot.token_buf[0..slot.token_len]}) catch return -4;

    // Parse URI
    const uri = std.Uri.parse(url_str) catch return -4;

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers_buf: [3]std.http.Header = .{
        .{ .name = "PRIVATE-TOKEN", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = "boj-server/1.0 (gitlab-api-mcp cartridge)" },
    };

    // Determine body slice
    const body_slice: ?[]const u8 = if (body != null and body_len > 0) blk: {
        const blen: usize = std.math.cast(usize, body_len) orelse break :blk null;
        break :blk body[0..blen];
    } else null;

    const cap: usize = std.math.cast(usize, out_cap) orelse return -4;

    // Fetch the request (Zig 0.15 API — replaces open/send/wait)
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const fetch_result = client.fetch(.{
        .method = http_method,
        .location = .{ .uri = uri },
        .extra_headers = &headers_buf,
        .payload = body_slice,
        .response_writer = &aw.writer,
    }) catch return -4;

    // Handle rate limiting (HTTP 429)
    const status_code = @intFromEnum(fetch_result.status);
    if (status_code == 429) {
        slot.state = .rate_limited;
        slot.rate_limit_remaining = 0;
        return -3;
    }

    // Copy response body into caller's buffer
    const response_bytes = aw.writer.buffered();
    const bytes_read = @min(response_bytes.len, cap);
    @memcpy(out_buf[0..bytes_read], response_bytes[0..bytes_read]);
    out_len.* = @intCast(bytes_read);

    if (status_code >= 500) {
        slot.state = .err;
        return -4;
    }

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
/// HTTP dispatch is performed via std.http.Client to <base_url>/api/graphql
/// with Private-Token authentication header.
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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const base_url = slot.base_url_buf[0..slot.base_url_len];
    const url_str = std.fmt.allocPrint(allocator, "{s}/api/graphql", .{base_url}) catch return -4;

    // Build GraphQL JSON body
    const query_slice = query[0..qlen];
    const vlen: usize = std.math.cast(usize, variables_len) orelse 0;
    const gql_body = if (variables != null and vlen > 0)
        std.fmt.allocPrint(allocator, "{{\"query\":{s},\"variables\":{s}}}", .{ query_slice, variables[0..vlen] }) catch return -4
    else
        std.fmt.allocPrint(allocator, "{{\"query\":{s}}}", .{query_slice}) catch return -4;

    const auth_header = std.fmt.allocPrint(allocator, "{s}", .{slot.token_buf[0..slot.token_len]}) catch return -4;

    const uri = std.Uri.parse(url_str) catch return -4;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers_buf: [3]std.http.Header = .{
        .{ .name = "PRIVATE-TOKEN", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = "boj-server/1.0 (gitlab-api-mcp cartridge)" },
    };

    // Fetch the request (Zig 0.15 API — replaces open/send/wait)
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const fetch_result = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .extra_headers = &headers_buf,
        .payload = gql_body,
        .response_writer = &aw.writer,
    }) catch return -4;

    const status_code = @intFromEnum(fetch_result.status);
    if (status_code == 429) {
        slot.state = .rate_limited;
        slot.rate_limit_remaining = 0;
        return -3;
    }

    const response_bytes = aw.writer.buffered();
    const bytes_read = @min(response_bytes.len, cap);
    @memcpy(out_buf[0..bytes_read], response_bytes[0..bytes_read]);
    out_len.* = @intCast(bytes_read);
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
/// HTTP dispatch is performed via std.http.Client to POST /projects/:id/remote_mirrors
/// with Private-Token authentication header.
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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const base_url = slot.base_url_buf[0..slot.base_url_len];
    const api_version = slot.api_version_buf[0..slot.api_version_len];
    const target_slice = target_url[0..tlen];

    // POST /projects/:id/remote_mirrors
    const url_str = std.fmt.allocPrint(allocator, "{s}/api/{s}/projects/{d}/remote_mirrors", .{ base_url, api_version, project_id }) catch return -4;
    const mirror_body = std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\",\"enabled\":true}}", .{target_slice}) catch return -4;
    const auth_header = std.fmt.allocPrint(allocator, "{s}", .{slot.token_buf[0..slot.token_len]}) catch return -4;

    const uri = std.Uri.parse(url_str) catch return -4;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers_buf_mirror: [3]std.http.Header = .{
        .{ .name = "PRIVATE-TOKEN", .value = auth_header },
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "User-Agent", .value = "boj-server/1.0 (gitlab-api-mcp cartridge)" },
    };

    // Fetch the request (Zig 0.15 API — replaces open/send/wait)
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const fetch_result = client.fetch(.{
        .method = .POST,
        .location = .{ .uri = uri },
        .extra_headers = &headers_buf_mirror,
        .payload = mirror_body,
        .response_writer = &aw.writer,
    }) catch return -4;

    const status_code = @intFromEnum(fetch_result.status);
    if (status_code == 429) {
        slot.state = .rate_limited;
        slot.rate_limit_remaining = 0;
        return -3;
    }

    const response_bytes = aw.writer.buffered();
    const bytes_read = @min(response_bytes.len, cap);
    @memcpy(out_buf[0..bytes_read], response_bytes[0..bytes_read]);
    out_len.* = @intCast(bytes_read);
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
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "gitlab-api-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "gitlab_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gitlab_list_projects"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gitlab_get_project"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gitlab_list_issues"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gitlab_create_issue"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gitlab_create_mr"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "gitlab_setup_mirror"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "authentication lifecycle" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Should be unauthenticated
    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_state(slot));

    // Authenticate with default gitlab.com
    const token = "glpat-xxxxxxxxxxxxxxxxxxxx"; // hypatia-ignore: test fixture — placeholder format only
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

test "self-hosted instance auth" {
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

    // Verify request requires auth (pre-auth rejection tested elsewhere).
    // Real HTTP dispatch will attempt to connect to self-hosted instance.
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

test "graphql pre-auth rejection" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Cannot issue GraphQL before authentication
    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;
    const query = "{ currentUser { name } }";
    try std.testing.expect(gitlab_api_mcp_graphql(
        slot,
        query,
        @intCast(query.len),
        null,
        0,
        &buf,
        1024,
        &out_len,
    ) != 0);

    try std.testing.expectEqual(@as(c_int, 0), gitlab_api_mcp_session_close(slot));
}

test "mirror pre-auth rejection" {
    gitlab_api_mcp_reset();

    const slot = gitlab_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Cannot setup mirror before authentication
    var buf: [1024]u8 = undefined;
    var out_len: c_int = 0;
    const target = "https://github.com/org/repo.git";
    try std.testing.expect(gitlab_api_mcp_setup_mirror(
        slot,
        42,
        target,
        @intCast(target.len),
        &buf,
        1024,
        &out_len,
    ) != 0);

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

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns gitlab-api-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("gitlab-api-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "gitlab_authenticate",
        "gitlab_list_projects",
        "gitlab_get_project",
        "gitlab_list_issues",
        "gitlab_create_issue",
        "gitlab_create_mr",
        "gitlab_setup_mirror",
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
    const rc = boj_cartridge_invoke("gitlab_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
