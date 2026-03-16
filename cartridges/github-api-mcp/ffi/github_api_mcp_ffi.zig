// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// github_api_mcp_ffi.zig — C-ABI FFI for GitHub REST & GraphQL API cartridge.
//
// Implements the state machine defined in GithubApiMcp.SafeGit (Idris2 ABI).
// Thread-safe via std.Thread.Mutex. HTTP client stubs for GitHub API.
// Auth tokens retrieved from vault-mcp zero-knowledge proxy.

const std = @import("std");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// GitHub REST API base URL.
pub const REST_BASE: []const u8 = "https://api.github.com";

/// GitHub GraphQL API endpoint.
pub const GRAPHQL_ENDPOINT: []const u8 = "https://api.github.com/graphql";

/// Maximum concurrent sessions.
const MAX_SESSIONS: usize = 16;

/// Output buffer size per session (64 KiB).
const BUF_SIZE: usize = 65536;

/// Token buffer size (tokens are typically < 256 bytes).
const TOKEN_BUF_SIZE: usize = 512;

// ---------------------------------------------------------------------------
// Auth state machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

/// Authentication and rate-limit state.
///
/// Unauthenticated = 0, Authenticated = 1, RateLimited = 2, Error = 3
pub const AuthState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// Check if a transition between two AuthStates is valid.
///
/// Valid transitions:
///   Unauthenticated -> Authenticated   (Authenticate)
///   Authenticated   -> RateLimited     (Throttle)
///   RateLimited     -> Authenticated   (Resume after cooldown)
///   Authenticated   -> Error           (Fault)
///   Error           -> Unauthenticated (ResetError)
///   Authenticated   -> Unauthenticated (Logout)
fn isValidTransition(from: AuthState, to: AuthState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .rate_limited or to == .err or to == .unauthenticated,
        .rate_limited => to == .authenticated,
        .err => to == .unauthenticated,
    };
}

// ---------------------------------------------------------------------------
// GitHub action codes (matches Idris2 GitHubAction exactly)
// ---------------------------------------------------------------------------

/// GitHub API action identifiers.
pub const GitHubAction = enum(c_int) {
    list_repos = 0,
    get_repo = 1,
    create_issue = 2,
    list_issues = 3,
    get_issue = 4,
    comment_issue = 5,
    create_pr = 6,
    list_prs = 7,
    get_pr = 8,
    merge_pr = 9,
    review_pr = 10,
    list_branches = 11,
    create_branch = 12,
    search_code = 13,
    search_issues = 14,
    list_actions = 15,
    get_release = 16,
    create_release = 17,
    get_file_contents = 18,
    push_files = 19,
};

/// Check if an action is a write/mutation operation.
fn actionIsMutation(action: GitHubAction) bool {
    return switch (action) {
        .create_issue, .comment_issue, .create_pr, .merge_pr, .review_pr, .create_branch, .create_release, .push_files => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Rate limit tracking
// ---------------------------------------------------------------------------

/// Rate limit information parsed from GitHub API response headers.
const RateLimit = struct {
    /// Remaining calls in the current window.
    remaining: u32 = 5000,
    /// Unix epoch seconds when the window resets.
    reset_time: u64 = 0,
    /// Maximum calls permitted per window.
    limit: u32 = 5000,
};

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const SessionSlot = struct {
    active: bool = false,
    state: AuthState = .unauthenticated,
    token_buf: [TOKEN_BUF_SIZE]u8 = undefined,
    token_len: usize = 0,
    out_buf: [BUF_SIZE]u8 = undefined,
    out_len: usize = 0,
    rate_limit: RateLimit = .{},
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Get a mutable reference to a valid session slot.
/// Returns null if index is out of range or slot is not active.
fn getSlot(slot_idx: c_int) ?*SessionSlot {
    const idx: usize = std.math.cast(usize, slot_idx) orelse return null;
    if (idx >= MAX_SESSIONS) return null;
    const slot = &sessions[idx];
    if (!slot.active) return null;
    return slot;
}

/// Parse rate-limit headers from a response string.
/// Looks for X-RateLimit-Remaining, X-RateLimit-Reset, X-RateLimit-Limit.
fn parseRateLimitHeaders(headers: []const u8) RateLimit {
    var rl = RateLimit{};
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "x-ratelimit-remaining:")) {
            const val = std.mem.trimLeft(u8, line["x-ratelimit-remaining:".len..], " ");
            rl.remaining = std.fmt.parseInt(u32, val, 10) catch rl.remaining;
        } else if (std.ascii.startsWithIgnoreCase(line, "x-ratelimit-reset:")) {
            const val = std.mem.trimLeft(u8, line["x-ratelimit-reset:".len..], " ");
            rl.reset_time = std.fmt.parseInt(u64, val, 10) catch rl.reset_time;
        } else if (std.ascii.startsWithIgnoreCase(line, "x-ratelimit-limit:")) {
            const val = std.mem.trimLeft(u8, line["x-ratelimit-limit:".len..], " ");
            rl.limit = std.fmt.parseInt(u32, val, 10) catch rl.limit;
        }
    }
    return rl;
}

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn github_api_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(AuthState, from) catch return 0;
    const t = std.meta.intToEnum(AuthState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Open a new session (starts Unauthenticated).
/// Returns slot index (>= 0) or -1 if no free slots.
pub export fn github_api_mcp_session_open() c_int {
    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .unauthenticated;
            slot.token_len = 0;
            slot.out_len = 0;
            slot.rate_limit = .{};
            return @intCast(idx);
        }
    }
    return -1;
}

/// Close a session. Returns 0 on success, -1 if invalid slot.
/// Any state can be closed (session teardown is unconditional).
pub export fn github_api_mcp_session_close(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;

    // Zero-fill token for security before releasing slot
    @memset(&slot.token_buf, 0);
    slot.token_len = 0;
    slot.active = false;
    slot.state = .unauthenticated;
    slot.out_len = 0;
    slot.rate_limit = .{};
    return 0;
}

/// Get the current AuthState of a session. Returns state int or -1 if invalid.
pub export fn github_api_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intFromEnum(slot.state);
}

// ---------------------------------------------------------------------------
// C-ABI exports — authentication
// ---------------------------------------------------------------------------

/// Authenticate a session with a Bearer token (retrieved from vault-mcp).
/// Transitions Unauthenticated -> Authenticated.
/// Returns 0 on success, -1 invalid slot, -2 bad transition, -3 token too long.
pub export fn github_api_mcp_authenticate(slot_idx: c_int, token_ptr: [*]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    const len: usize = std.math.cast(usize, token_len) orelse return -3;
    if (len == 0 or len > TOKEN_BUF_SIZE) return -3;

    @memcpy(slot.token_buf[0..len], token_ptr[0..len]);
    slot.token_len = len;
    slot.state = .authenticated;
    slot.rate_limit = .{};
    return 0;
}

/// Logout (Authenticated -> Unauthenticated). Zeroes the stored token.
/// Returns 0 on success, -1 invalid slot, -2 bad transition.
pub export fn github_api_mcp_logout(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (!isValidTransition(slot.state, .unauthenticated)) return -2;

    @memset(&slot.token_buf, 0);
    slot.token_len = 0;
    slot.state = .unauthenticated;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — rate limiting
// ---------------------------------------------------------------------------

/// Get remaining rate limit for a session. Returns remaining count, or -1 on error.
pub export fn github_api_mcp_rate_limit_remaining(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    return @intCast(slot.rate_limit.remaining);
}

/// Get rate limit reset time (unix epoch seconds). Returns 0 if unset, -1 on error.
pub export fn github_api_mcp_rate_limit_reset(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    // Truncate to c_int; callers needing full u64 use the struct directly
    return @intCast(@as(u32, @truncate(slot.rate_limit.reset_time)));
}

/// Manually transition to RateLimited state (Authenticated -> RateLimited).
/// Returns 0 on success, -1 invalid slot, -2 bad transition.
pub export fn github_api_mcp_throttle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (!isValidTransition(slot.state, .rate_limited)) return -2;

    slot.state = .rate_limited;
    return 0;
}

/// Resume from RateLimited -> Authenticated (after cooldown elapsed).
/// Returns 0 on success, -1 invalid slot, -2 bad transition.
pub export fn github_api_mcp_resume(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    slot.state = .authenticated;
    slot.rate_limit.remaining = slot.rate_limit.limit;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — error handling
// ---------------------------------------------------------------------------

/// Signal an error (Authenticated -> Error). Returns 0 on success.
pub export fn github_api_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    slot.state = .err;
    return 0;
}

/// Reset from Error -> Unauthenticated. Returns 0 on success.
pub export fn github_api_mcp_reset_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (!isValidTransition(slot.state, .unauthenticated)) return -2;

    slot.state = .unauthenticated;
    @memset(&slot.token_buf, 0);
    slot.token_len = 0;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — GitHub API request stubs
// ---------------------------------------------------------------------------

/// Issue a REST API request.
///
/// Parameters:
///   slot_idx   — session slot
///   method_ptr — HTTP method ("GET", "POST", "PUT", "PATCH", "DELETE")
///   method_len — length of method string
///   path_ptr   — API path (e.g. "/repos/owner/name/issues")
///   path_len   — length of path string
///   body_ptr   — request body (JSON), may be null for GET/DELETE
///   body_len   — length of body (0 if no body)
///   out_ptr    — pointer to caller-provided output buffer
///   out_cap    — capacity of output buffer
///
/// Returns: bytes written to out_ptr on success, or negative error code.
///   -1 = invalid slot, -2 = not authenticated, -3 = rate limited,
///   -4 = buffer too small, -5 = network/HTTP error stub
pub export fn github_api_mcp_request(
    slot_idx: c_int,
    method_ptr: [*]const u8,
    method_len: c_int,
    path_ptr: [*]const u8,
    path_len: c_int,
    body_ptr: ?[*]const u8,
    body_len: c_int,
    out_ptr: [*]u8,
    out_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (slot.state != .authenticated) {
        if (slot.state == .rate_limited) return -3;
        return -2;
    }

    const m_len: usize = std.math.cast(usize, method_len) orelse return -5;
    const p_len: usize = std.math.cast(usize, path_len) orelse return -5;
    const b_len: usize = std.math.cast(usize, body_len) orelse return -5;
    const o_cap: usize = std.math.cast(usize, out_cap) orelse return -4;

    // Stub: construct a JSON envelope describing what would be sent.
    // In production, this calls std.http.Client against REST_BASE.
    _ = body_ptr;
    _ = b_len;
    const method = method_ptr[0..m_len];
    const path = path_ptr[0..p_len];

    const response = std.fmt.bufPrint(out_ptr[0..o_cap], "{{\"stub\":true,\"method\":\"{s}\",\"url\":\"{s}{s}\",\"state\":\"authenticated\"}}", .{ method, REST_BASE, path }) catch return -4;

    // Simulate rate-limit decrement
    if (slot.rate_limit.remaining > 0) {
        slot.rate_limit.remaining -= 1;
    }
    if (slot.rate_limit.remaining == 0) {
        slot.state = .rate_limited;
    }

    return @intCast(response.len);
}

/// Issue a GraphQL query.
///
/// Parameters:
///   slot_idx      — session slot
///   query_ptr     — GraphQL query string
///   query_len     — length of query string
///   variables_ptr — JSON variables (may be null)
///   variables_len — length of variables string (0 if null)
///   out_ptr       — pointer to output buffer
///   out_cap       — capacity of output buffer
///
/// Returns: bytes written on success, or negative error code (same codes as request).
pub export fn github_api_mcp_graphql(
    slot_idx: c_int,
    query_ptr: [*]const u8,
    query_len: c_int,
    variables_ptr: ?[*]const u8,
    variables_len: c_int,
    out_ptr: [*]u8,
    out_cap: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    const slot = getSlot(slot_idx) orelse return -1;
    if (slot.state != .authenticated) {
        if (slot.state == .rate_limited) return -3;
        return -2;
    }

    const q_len: usize = std.math.cast(usize, query_len) orelse return -5;
    const v_len: usize = std.math.cast(usize, variables_len) orelse return -5;
    const o_cap: usize = std.math.cast(usize, out_cap) orelse return -4;

    _ = query_ptr;
    _ = q_len;
    _ = variables_ptr;
    _ = v_len;

    // Stub: return a JSON envelope for GraphQL
    const response = std.fmt.bufPrint(out_ptr[0..o_cap], "{{\"stub\":true,\"endpoint\":\"{s}\",\"state\":\"authenticated\"}}", .{GRAPHQL_ENDPOINT}) catch return -4;

    if (slot.rate_limit.remaining > 0) {
        slot.rate_limit.remaining -= 1;
    }
    if (slot.rate_limit.remaining == 0) {
        slot.state = .rate_limited;
    }

    return @intCast(response.len);
}

// ---------------------------------------------------------------------------
// C-ABI exports — action validation
// ---------------------------------------------------------------------------

/// Check if an action code is valid. Returns 1 if valid, 0 if out of range.
pub export fn github_api_mcp_valid_action(code: c_int) c_int {
    _ = std.meta.intToEnum(GitHubAction, code) catch return 0;
    return 1;
}

/// Check if an action is a mutation. Returns 1 for mutation, 0 for read-only, -1 for invalid.
pub export fn github_api_mcp_is_mutation(code: c_int) c_int {
    const action = std.meta.intToEnum(GitHubAction, code) catch return -1;
    return if (actionIsMutation(action)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — reset (test/debug)
// ---------------------------------------------------------------------------

/// Reset all sessions (test/debug use only). Zeroes all token material.
pub export fn github_api_mcp_reset() void {
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

test "auth state transitions" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_can_transition(0, 1)); // Unauth -> Auth
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_can_transition(1, 2)); // Auth -> RateLimited
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_can_transition(2, 1)); // RateLimited -> Auth
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_can_transition(1, 3)); // Auth -> Error
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_can_transition(3, 0)); // Error -> Unauth
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_can_transition(1, 0)); // Auth -> Unauth (Logout)

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_can_transition(0, 2)); // Unauth -> RateLimited
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_can_transition(0, 3)); // Unauth -> Error
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_can_transition(2, 0)); // RateLimited -> Unauth
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_can_transition(2, 3)); // RateLimited -> Error
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_can_transition(3, 1)); // Error -> Auth

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_can_transition(99, 0));
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_can_transition(0, 99));
}

test "session lifecycle with authentication" {
    github_api_mcp_reset();

    // Open session (starts Unauthenticated)
    const slot = github_api_mcp_session_open();
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_session_state(slot)); // Unauthenticated

    // Authenticate
    const token = "ghp_test_token_12345";
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_authenticate(slot, token.ptr, @intCast(token.len)));
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_session_state(slot)); // Authenticated

    // Check rate limit (default 5000)
    try std.testing.expectEqual(@as(c_int, 5000), github_api_mcp_rate_limit_remaining(slot));

    // Logout
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_logout(slot));
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_session_state(slot)); // Unauthenticated

    // Close
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_session_close(slot));
}

test "rate limiting flow" {
    github_api_mcp_reset();

    const slot = github_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    const token = "ghp_ratelimit_test";
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_authenticate(slot, token.ptr, @intCast(token.len)));

    // Manually throttle
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), github_api_mcp_session_state(slot)); // RateLimited

    // Cannot throttle again from RateLimited
    try std.testing.expectEqual(@as(c_int, -2), github_api_mcp_throttle(slot));

    // Resume after cooldown
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_resume(slot));
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_session_state(slot)); // Authenticated

    _ = github_api_mcp_session_close(slot);
}

test "error handling flow" {
    github_api_mcp_reset();

    const slot = github_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    const token = "ghp_error_test";
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_authenticate(slot, token.ptr, @intCast(token.len)));

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), github_api_mcp_session_state(slot)); // Error

    // Cannot authenticate from Error (must reset first)
    const token2 = "ghp_retry";
    try std.testing.expectEqual(@as(c_int, -2), github_api_mcp_authenticate(slot, token2.ptr, @intCast(token2.len)));

    // Reset error -> Unauthenticated
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_reset_error(slot));
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_session_state(slot)); // Unauthenticated

    // Now can authenticate again
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_authenticate(slot, token.ptr, @intCast(token.len)));
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_session_state(slot)); // Authenticated

    _ = github_api_mcp_session_close(slot);
}

test "REST request stub" {
    github_api_mcp_reset();

    const slot = github_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Cannot request before auth
    var buf: [1024]u8 = undefined;
    const method = "GET";
    const path = "/repos/hyperpolymath/boj-server";
    try std.testing.expect(github_api_mcp_request(slot, method.ptr, @intCast(method.len), path.ptr, @intCast(path.len), null, 0, &buf, 1024) < 0);

    // Authenticate then request
    const token = "ghp_stub_test";
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_authenticate(slot, token.ptr, @intCast(token.len)));

    const written = github_api_mcp_request(slot, method.ptr, @intCast(method.len), path.ptr, @intCast(path.len), null, 0, &buf, 1024);
    try std.testing.expect(written > 0);

    // Verify the response contains stub marker
    const response = buf[0..@intCast(written)];
    try std.testing.expect(std.mem.indexOf(u8, response, "\"stub\":true") != null);

    _ = github_api_mcp_session_close(slot);
}

test "GraphQL request stub" {
    github_api_mcp_reset();

    const slot = github_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    const token = "ghp_graphql_test";
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_authenticate(slot, token.ptr, @intCast(token.len)));

    var buf: [1024]u8 = undefined;
    const query = "{ viewer { login } }";
    const written = github_api_mcp_graphql(slot, query.ptr, @intCast(query.len), null, 0, &buf, 1024);
    try std.testing.expect(written > 0);

    const response = buf[0..@intCast(written)];
    try std.testing.expect(std.mem.indexOf(u8, response, "graphql") != null);

    _ = github_api_mcp_session_close(slot);
}

test "action validation" {
    // Valid actions (0..19)
    var i: c_int = 0;
    while (i < 20) : (i += 1) {
        try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_valid_action(i));
    }
    // Invalid
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_valid_action(20));
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_valid_action(-1));
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_valid_action(99));

    // Mutation checks
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_is_mutation(0));  // ListRepos = read
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_is_mutation(2));  // CreateIssue = mutation
    try std.testing.expectEqual(@as(c_int, 1), github_api_mcp_is_mutation(9));  // MergePR = mutation
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_is_mutation(13)); // SearchCode = read
    try std.testing.expectEqual(@as(c_int, -1), github_api_mcp_is_mutation(99)); // invalid
}

test "slot exhaustion" {
    github_api_mcp_reset();

    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = github_api_mcp_session_open();
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), github_api_mcp_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), github_api_mcp_session_close(slots[0]));
    const new_slot = github_api_mcp_session_open();
    try std.testing.expect(new_slot >= 0);
}
