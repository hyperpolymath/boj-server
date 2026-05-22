// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// rokur_mcp_ffi.zig — C-ABI FFI for the rokur-mcp cartridge.
//
// Container pre-start secrets gate. Communicates with the Rokur sidecar
// service (Deno, default http://127.0.0.1:9090) to validate that required
// secrets are present before allowing containers to start.
//
// Thread-safe via std.Thread.Mutex. No heap allocations for result buffers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Gate state machine (matches Idris2 ABI: RokurMcp.SafeGate)
// ---------------------------------------------------------------------------

pub const GateState = enum(c_int) {
    idle = 0,
    checking = 1,
    allowed = 2,
    denied = 3,
    err = 4,
};

pub const GateAction = enum(c_int) {
    authorize_start = 0,
    check_status = 1,
    reload_secrets = 2,
    query_health = 3,
};

fn isValidTransition(from: GateState, to: GateState) bool {
    return switch (from) {
        .idle => to == .checking,
        .checking => to == .allowed or to == .denied or to == .err,
        .allowed => to == .idle,
        .denied => to == .idle,
        .err => to == .idle,
    };
}

fn isActionPermitted(state: GateState, action: GateAction) bool {
    return switch (action) {
        .query_health => true,
        .check_status => true,
        .reload_secrets => state == .idle or state == .allowed or state == .denied,
        .authorize_start => state == .idle,
    };
}

// ---------------------------------------------------------------------------
// Rokur proxy state
// ---------------------------------------------------------------------------

const RESULT_BUF_SIZE: usize = 4096;
const ROKUR_DEFAULT_URL: []const u8 = "http://127.0.0.1:9090";

const GateProxy = struct {
    state: GateState = .idle,
    result_buf: [RESULT_BUF_SIZE]u8 = undefined,
    result_len: usize = 0,
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
    last_verdict_allowed: bool = false,
    required_count: u32 = 0,
    missing_count: u32 = 0,
    check_count: u32 = 0,
};

var proxy: GateProxy = .{};
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn setError(msg: []const u8) void {
    const len = @min(msg.len, proxy.last_error.len);
    @memcpy(proxy.last_error[0..len], msg[0..len]);
    proxy.last_error_len = len;
}

/// Call Rokur sidecar REST API via curl.
/// We use curl rather than std.http to avoid TLS complexity in Zig.
fn callRokur(path: []const u8, method: []const u8, token: []const u8) !usize {
    // Build URL
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}{s}", .{ ROKUR_DEFAULT_URL, path }) catch return error.UrlTooLong;

    // Build auth header
    var auth_buf: [256]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_buf, "X-Rokur-Token: {s}", .{token}) catch return error.TokenTooLong;

    const argv = [_][]const u8{
        "curl", "-s", "-X", method, "-H", auth_header, url,
    };

    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = child.stdout.?;
    const bytes_read = stdout.readAll(&proxy.result_buf) catch |e| {
        _ = child.wait() catch {};
        return e;
    };

    const stderr = child.stderr.?;
    const err_read = stderr.readAll(&proxy.last_error) catch 0;
    proxy.last_error_len = err_read;

    const term = try child.wait();
    if (term.Exited != 0) return error.CurlFailed;

    proxy.result_len = bytes_read;
    return bytes_read;
}

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

pub export fn rokur_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(GateState, from) catch return 0;
    const t = std.meta.intToEnum(GateState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

pub export fn rokur_mcp_state() c_int {
    mutex.lock();
    defer mutex.unlock();
    return @intFromEnum(proxy.state);
}

pub export fn rokur_mcp_transition(to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const target = std.meta.intToEnum(GateState, to) catch return -1;
    if (!isValidTransition(proxy.state, target)) return -2;
    proxy.state = target;
    return 0;
}

pub export fn rokur_mcp_action_permitted(action: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const a = std.meta.intToEnum(GateAction, action) catch return 0;
    return if (isActionPermitted(proxy.state, a)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — gate operations
// ---------------------------------------------------------------------------

/// POST /v1/authorize-start — request pre-start authorization.
/// Calls Rokur sidecar, transitions to Allowed/Denied/Error.
///
/// Parameters:
///   token_ptr/token_len: ROKUR_API_TOKEN for authentication
///   image_ptr/image_len: container image name (for policy context)
///
/// Returns: bytes in result buffer, or negative error code.
///   -1 = not in idle state
///   -2 = Rokur call failed
///   -3 = null pointer
pub export fn rokur_mcp_authorize(
    token_ptr: [*c]const u8,
    token_len: c_int,
    image_ptr: [*c]const u8,
    image_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (proxy.state != .idle) {
        setError("gate not in idle state");
        return -1;
    }

    if (token_ptr == null) return -3;

    const t_ulen: usize = std.math.cast(usize, token_len) orelse return -3;
    const token = token_ptr[0..t_ulen];

    // image_ptr/image_len reserved for future policy context (container name).
    // Currently Rokur's /v1/authorize-start doesn't require it in the URL,
    // but we validate the parameters for forward compatibility.
    if (image_ptr == null) return -3;
    const i_ulen: usize = std.math.cast(usize, image_len) orelse return -3;
    const image = image_ptr[0..i_ulen];
    _ = image;

    // Transition to checking
    proxy.state = .checking;
    proxy.check_count += 1;

    const bytes = callRokur("/v1/authorize-start", "POST", token) catch {
        setError("rokur sidecar unreachable");
        proxy.state = .err;
        return -2;
    };

    // Parse the "allowed" field from JSON response.
    // Rokur returns: {"allowed":true/false, "policy":"allow"/"deny", ...}
    const result = proxy.result_buf[0..bytes];
    if (std.mem.indexOf(u8, result, "\"allowed\":true")) |_| {
        proxy.state = .allowed;
        proxy.last_verdict_allowed = true;
    } else {
        proxy.state = .denied;
        proxy.last_verdict_allowed = false;
    }

    return @intCast(bytes);
}

/// GET /health — Rokur sidecar liveness check.
pub export fn rokur_mcp_health(token_ptr: [*c]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (token_ptr == null) return -3;
    const t_ulen: usize = std.math.cast(usize, token_len) orelse return -3;
    const token = token_ptr[0..t_ulen];

    const bytes = callRokur("/health", "GET", token) catch {
        setError("rokur health check failed");
        return -2;
    };

    return @intCast(bytes);
}

/// GET /v1/secrets/status — query secrets presence status.
pub export fn rokur_mcp_secrets_status(token_ptr: [*c]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (token_ptr == null) return -3;
    const t_ulen: usize = std.math.cast(usize, token_len) orelse return -3;
    const token = token_ptr[0..t_ulen];

    const bytes = callRokur("/v1/secrets/status", "GET", token) catch {
        setError("rokur secrets status failed");
        return -2;
    };

    return @intCast(bytes);
}

/// POST /v1/secrets/reload — hot-reload required secrets.
pub export fn rokur_mcp_reload(token_ptr: [*c]const u8, token_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (token_ptr == null) return -3;
    const t_ulen: usize = std.math.cast(usize, token_len) orelse return -3;
    const token = token_ptr[0..t_ulen];

    const bytes = callRokur("/v1/secrets/reload", "POST", token) catch {
        setError("rokur reload failed");
        return -2;
    };

    return @intCast(bytes);
}

/// Read the result buffer from the last operation.
pub export fn rokur_mcp_read_result(out_ptr: [*c]u8, max_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (out_ptr == null) return -1;
    const umax: usize = std.math.cast(usize, max_len) orelse return -1;
    const copy_len = @min(proxy.result_len, umax);
    @memcpy(out_ptr[0..copy_len], proxy.result_buf[0..copy_len]);
    return @intCast(copy_len);
}

/// Read the last error message.
pub export fn rokur_mcp_read_error(out_ptr: [*c]u8, max_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (out_ptr == null) return -1;
    const umax: usize = std.math.cast(usize, max_len) orelse return -1;
    const copy_len = @min(proxy.last_error_len, umax);
    @memcpy(out_ptr[0..copy_len], proxy.last_error[0..copy_len]);
    return @intCast(copy_len);
}

/// Get the last authorization verdict (1=allowed, 0=denied).
pub export fn rokur_mcp_last_verdict() c_int {
    mutex.lock();
    defer mutex.unlock();
    return if (proxy.last_verdict_allowed) 1 else 0;
}

/// Get total authorization check count.
pub export fn rokur_mcp_check_count() c_int {
    mutex.lock();
    defer mutex.unlock();
    return @intCast(proxy.check_count);
}

/// Reset gate to initial state (test/debug only).
pub export fn rokur_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    proxy = .{};
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "rokur-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "rokur_authorize"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "rokur_health"))
        "{\"result\":{\"health\":\"healthy\",\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "rokur_secrets_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "rokur_reload"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "gate state transitions" {
    rokur_mcp_reset();
    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_state()); // idle

    // Idle -> Checking
    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_transition(1));
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_state());

    // Checking -> Allowed
    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_transition(2));
    try std.testing.expectEqual(@as(c_int, 2), rokur_mcp_state());

    // Allowed -> Idle (reset)
    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_transition(0));
    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_state());
}

test "invalid gate transitions" {
    rokur_mcp_reset();

    // Idle -> Allowed directly (must go through Checking)
    try std.testing.expectEqual(@as(c_int, -2), rokur_mcp_transition(2));

    // Idle -> Denied directly
    try std.testing.expectEqual(@as(c_int, -2), rokur_mcp_transition(3));

    // Go to Checking -> Denied
    _ = rokur_mcp_transition(1); // idle -> checking
    _ = rokur_mcp_transition(3); // checking -> denied

    // Denied -> Allowed (invalid, must reset to Idle first)
    try std.testing.expectEqual(@as(c_int, -2), rokur_mcp_transition(2));

    // Denied -> Idle (valid reset)
    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_transition(0));
}

test "gate transition validator" {
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_can_transition(0, 1)); // idle -> checking
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_can_transition(1, 2)); // checking -> allowed
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_can_transition(1, 3)); // checking -> denied
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_can_transition(1, 4)); // checking -> error
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_can_transition(2, 0)); // allowed -> idle
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_can_transition(3, 0)); // denied -> idle
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_can_transition(4, 0)); // error -> idle

    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_can_transition(0, 2)); // idle -> allowed
    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_can_transition(2, 3)); // allowed -> denied
}

test "action permissions" {
    rokur_mcp_reset();

    // Health always allowed
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_action_permitted(3));
    // Status always allowed
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_action_permitted(1));
    // Authorize requires idle
    try std.testing.expectEqual(@as(c_int, 1), rokur_mcp_action_permitted(0));

    // Transition to checking — authorize should be blocked
    _ = rokur_mcp_transition(1);
    try std.testing.expectEqual(@as(c_int, 0), rokur_mcp_action_permitted(0));
}

test "authorize requires idle state" {
    rokur_mcp_reset();
    _ = rokur_mcp_transition(1); // idle -> checking
    const result = rokur_mcp_authorize("token", 5, "nginx:latest", 12);
    try std.testing.expectEqual(@as(c_int, -1), result);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns rokur-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("rokur-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "rokur_authorize",
        "rokur_health",
        "rokur_secrets_status",
        "rokur_reload",
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
    const rc = boj_cartridge_invoke("rokur_authorize", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
