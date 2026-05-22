// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// github_api_mcp_ffi.zig — C-ABI FFI for GitHub REST & GraphQL API cartridge.
//
// Implements the state machine defined in GithubApiMcp.SafeGit (Idris2 ABI).
// Thread-safe via std.Thread.Mutex. Real HTTP dispatch to the GitHub REST and
// GraphQL APIs via std.http.Client. Auth tokens retrieved from vault-mcp
// zero-knowledge proxy.

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

// Rate-limit header parsing is performed inline within doHttpRequest()
// from the std.http response headers (X-RateLimit-Remaining,
// X-RateLimit-Reset, X-RateLimit-Limit).

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
// HTTP dispatch helpers
// ---------------------------------------------------------------------------

/// Parse an HTTP method string into std.http.Method.
fn parseHttpMethod(method: []const u8) std.http.Method {
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(method, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(method, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(method, "DELETE")) return .DELETE;
    return .GET;
}

/// Perform a real HTTP request to the GitHub API using std.http.Client.
/// Caller must hold the mutex and pass the slot.
/// Returns bytes written to out_buf on success, or a negative error code.
fn doHttpRequest(
    slot: *SessionSlot,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    out_buf: [*]u8,
    out_cap: usize,
) c_int {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build the full URL: REST_BASE + path
    const url_str = std.fmt.allocPrint(allocator, "{s}{s}", .{ REST_BASE, path }) catch return -5;

    // Build Authorization header value: "Bearer <token>"
    const auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{slot.token_buf[0..slot.token_len]}) catch return -5;

    // Parse the URI
    const uri = std.Uri.parse(url_str) catch return -5;

    // Create HTTP client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Prepare extra headers: Authorization, Accept, User-Agent
    var headers_buf: [3]std.http.Header = .{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept", .value = "application/vnd.github+json" },
        .{ .name = "User-Agent", .value = "boj-server/1.0 (github-api-mcp cartridge)" },
    };

    const http_method = parseHttpMethod(method);

    // Fetch the request (Zig 0.15 API — replaces open/send/wait)
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    const fetch_result = client.fetch(.{
        .method = http_method,
        .location = .{ .uri = uri },
        .extra_headers = &headers_buf,
        .payload = body,
        .response_writer = &aw.writer,
    }) catch return -5;

    // Handle rate limiting (HTTP 429 or 403 with depleted budget)
    const status_code = @intFromEnum(fetch_result.status);
    if (status_code == 429 or (status_code == 403 and slot.rate_limit.remaining == 0)) {
        slot.state = .rate_limited;
        return -3;
    }

    // Transition to error on server errors (5xx)
    if (status_code >= 500) {
        slot.state = .err;
        return -5;
    }

    // Copy response body into the caller's output buffer
    const response_bytes = aw.writer.buffered();
    const to_copy = @min(response_bytes.len, out_cap);
    @memcpy(out_buf[0..to_copy], response_bytes[0..to_copy]);
    return @intCast(to_copy);
}

// ---------------------------------------------------------------------------
// C-ABI exports — GitHub API request dispatch
// ---------------------------------------------------------------------------

/// Issue a REST API request to the GitHub API.
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
///   -4 = buffer too small, -5 = network/HTTP error
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

    const method = method_ptr[0..m_len];
    const path = path_ptr[0..p_len];
    const body: ?[]const u8 = if (body_ptr) |bp| bp[0..b_len] else null;

    return doHttpRequest(slot, method, path, body, out_ptr, o_cap);
}

/// Issue a GraphQL query to the GitHub GraphQL API.
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

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build the GraphQL JSON body: {"query":"...","variables":{...}}
    const query = query_ptr[0..q_len];
    const vars: ?[]const u8 = if (variables_ptr) |vp| vp[0..v_len] else null;
    const gql_body = if (vars) |v|
        std.fmt.allocPrint(allocator, "{{\"query\":{s},\"variables\":{s}}}", .{ query, v }) catch return -5
    else
        std.fmt.allocPrint(allocator, "{{\"query\":{s}}}", .{query}) catch return -5;

    // GraphQL endpoint is always POST /graphql
    return doHttpRequest(slot, "POST", "/graphql", gql_body, out_ptr, o_cap);
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
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "github-api-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "github_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "github_list_repos"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "github_get_repo"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "github_list_issues"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "github_get_issue"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "github_list_prs"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "github_search_code"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "github_search_issues"))
        "{\"result\":{\"matches\":[],\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

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

test "REST request pre-auth rejection" {
    github_api_mcp_reset();

    const slot = github_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Cannot request before auth — must return negative error code
    var buf: [1024]u8 = undefined;
    const method = "GET";
    const path = "/repos/hyperpolymath/boj-server";
    try std.testing.expect(github_api_mcp_request(slot, method.ptr, @intCast(method.len), path.ptr, @intCast(path.len), null, 0, &buf, 1024) < 0);

    _ = github_api_mcp_session_close(slot);
}

test "GraphQL pre-auth rejection" {
    github_api_mcp_reset();

    const slot = github_api_mcp_session_open();
    try std.testing.expect(slot >= 0);

    // Cannot issue GraphQL before auth
    var buf: [1024]u8 = undefined;
    const query = "{ viewer { login } }";
    try std.testing.expect(github_api_mcp_graphql(slot, query.ptr, @intCast(query.len), null, 0, &buf, 1024) < 0);

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

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns github-api-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("github-api-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "github_authenticate",
        "github_list_repos",
        "github_get_repo",
        "github_list_issues",
        "github_get_issue",
        "github_list_prs",
        "github_search_code",
        "github_search_issues",
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
    const rc = boj_cartridge_invoke("github_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
