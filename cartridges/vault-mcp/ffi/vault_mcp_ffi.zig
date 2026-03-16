// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vault_mcp_ffi.zig — C-ABI FFI for the vault-mcp cartridge.
//
// Zero-knowledge credential proxy: BoJ cartridges never see credentials.
// The vault (reasonably-good-token-vault) is accessed via the Ada CLI
// (svalinn_cli) or Unix domain socket at /run/svalinn/api.sock.
//
// Thread-safe via std.Thread.Mutex. No heap allocations for result buffers.

const std = @import("std");

// ---------------------------------------------------------------------------
// Vault state machine (matches Idris2 ABI: VaultMcp.SafeSecrets)
// ---------------------------------------------------------------------------

/// Vault lifecycle states for the zero-knowledge credential proxy.
pub const VaultState = enum(c_int) {
    /// Vault is sealed; no operations until unlock + MFA.
    locked = 0,
    /// Unlock requested; awaiting second factor confirmation.
    mfa_pending = 1,
    /// Vault is open; credential-proxied operations permitted.
    unlocked = 2,
    /// Vault permanently sealed; requires full re-init.
    sealed = 3,
};

/// Vault actions matching the MCP tool surface.
pub const VaultAction = enum(c_int) {
    execute = 0,
    list = 1,
    rotate = 2,
    status = 3,
    verify = 4,
};

/// Check if a vault state transition is valid.
/// Transition graph:
///   Locked -> MfaPending (begin unlock)
///   MfaPending -> Unlocked (MFA confirmed)
///   MfaPending -> Locked (MFA rejected/timeout)
///   Unlocked -> Locked (lock)
///   Unlocked -> Sealed (permanent seal)
///   Locked -> Sealed (seal without unlock)
fn isValidTransition(from: VaultState, to: VaultState) bool {
    return switch (from) {
        .locked => to == .mfa_pending or to == .sealed,
        .mfa_pending => to == .unlocked or to == .locked,
        .unlocked => to == .locked or to == .sealed,
        .sealed => false, // Terminal state — no transitions out
    };
}

/// Check if an action is permitted in the given vault state.
fn isActionPermitted(state: VaultState, action: VaultAction) bool {
    return switch (action) {
        .status => true, // Always available
        else => state == .unlocked,
    };
}

// ---------------------------------------------------------------------------
// Vault proxy state (thread-safe, single instance)
// ---------------------------------------------------------------------------

/// Result buffer size for CLI output capture.
const RESULT_BUF_SIZE: usize = 8192;

/// Socket path for the svalinn daemon.
const SVALINN_SOCKET: []const u8 = "/run/svalinn/api.sock";

/// Path to the svalinn Ada CLI binary.
const SVALINN_CLI: []const u8 = "svalinn_cli";

/// Thread-safe vault proxy state.
const VaultProxy = struct {
    state: VaultState = .locked,
    result_buf: [RESULT_BUF_SIZE]u8 = undefined,
    result_len: usize = 0,
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
    credential_count: u32 = 0,
    last_access_epoch: i64 = 0,
};

var proxy: VaultProxy = .{};
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Run svalinn_cli with the given arguments and capture stdout.
/// Returns the number of bytes written to proxy.result_buf, or error.
fn runSvalinnCli(args: []const []const u8) !usize {
    var argv = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer argv.deinit();
    try argv.append(SVALINN_CLI);
    for (args) |arg| {
        try argv.append(arg);
    }

    var child = std.process.Child.init(argv.items, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read stdout into proxy result buffer
    const stdout = child.stdout.?;
    const bytes_read = stdout.readAll(&proxy.result_buf) catch |e| {
        _ = child.wait() catch {};
        return e;
    };

    // Read stderr into last_error buffer
    const stderr = child.stderr.?;
    const err_read = stderr.readAll(&proxy.last_error) catch 0;
    proxy.last_error_len = err_read;

    const term = try child.wait();
    if (term.Exited != 0) {
        return error.CliNonZeroExit;
    }

    proxy.result_len = bytes_read;
    proxy.last_access_epoch = std.time.timestamp();
    return bytes_read;
}

/// Store an error message in the proxy error buffer.
fn setError(msg: []const u8) void {
    const len = @min(msg.len, proxy.last_error.len);
    @memcpy(proxy.last_error[0..len], msg[0..len]);
    proxy.last_error_len = len;
}

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a vault state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn vault_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(VaultState, from) catch return 0;
    const t = std.meta.intToEnum(VaultState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Get current vault state. Returns state integer.
pub export fn vault_mcp_state() c_int {
    mutex.lock();
    defer mutex.unlock();
    return @intFromEnum(proxy.state);
}

/// Transition vault to a new state. Returns 0 on success, -1 invalid state, -2 bad transition.
pub export fn vault_mcp_transition(to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const target = std.meta.intToEnum(VaultState, to) catch return -1;
    if (!isValidTransition(proxy.state, target)) return -2;
    proxy.state = target;
    return 0;
}

/// Check if an action is permitted in the current state. Returns 1 or 0.
pub export fn vault_mcp_action_permitted(action: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const a = std.meta.intToEnum(VaultAction, action) catch return 0;
    return if (isActionPermitted(proxy.state, a)) 1 else 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — vault operations
// ---------------------------------------------------------------------------

/// Execute a command with vault-managed credentials.
/// The credential_hint tells the vault which service needs auth.
/// The command is executed by svalinn_cli, which injects the credential
/// into the environment — this FFI layer never sees the secret.
///
/// Parameters:
///   command_ptr/command_len: the shell command to execute
///   hint_ptr/hint_len: credential hint (e.g. "github.com")
///
/// Returns: number of bytes in result buffer, or negative error code.
///   -1 = vault not unlocked
///   -2 = CLI execution failed
///   -3 = null pointer
pub export fn vault_mcp_execute(
    command_ptr: [*c]const u8,
    command_len: c_int,
    hint_ptr: [*c]const u8,
    hint_len: c_int,
) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (proxy.state != .unlocked) {
        setError("vault is not unlocked");
        return -1;
    }

    if (command_ptr == null or hint_ptr == null) return -3;

    const cmd_ulen: usize = std.math.cast(usize, command_len) orelse return -3;
    const hint_ulen: usize = std.math.cast(usize, hint_len) orelse return -3;
    const command = command_ptr[0..cmd_ulen];
    const hint = hint_ptr[0..hint_ulen];

    const args = [_][]const u8{ "get", hint, "--exec", command };
    const bytes = runSvalinnCli(&args) catch {
        setError("svalinn_cli execution failed");
        return -2;
    };

    return @intCast(bytes);
}

/// List credential hints available in the vault.
/// Returns number of bytes in result buffer, or negative error code.
pub export fn vault_mcp_list() c_int {
    mutex.lock();
    defer mutex.unlock();

    if (proxy.state != .unlocked) {
        setError("vault is not unlocked");
        return -1;
    }

    const args = [_][]const u8{"list"};
    const bytes = runSvalinnCli(&args) catch {
        setError("svalinn_cli list failed");
        return -2;
    };

    return @intCast(bytes);
}

/// Query vault status. Available in any state.
/// Returns number of bytes in result buffer, or negative error code.
pub export fn vault_mcp_status() c_int {
    mutex.lock();
    defer mutex.unlock();

    const args = [_][]const u8{"status"};
    const bytes = runSvalinnCli(&args) catch {
        setError("svalinn_cli status failed");
        return -2;
    };

    return @intCast(bytes);
}

/// Verify credential integrity for a given hint.
/// Returns number of bytes in result buffer, or negative error code.
pub export fn vault_mcp_verify(hint_ptr: [*c]const u8, hint_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (proxy.state != .unlocked) {
        setError("vault is not unlocked");
        return -1;
    }

    if (hint_ptr == null) return -3;

    const ulen: usize = std.math.cast(usize, hint_len) orelse return -3;
    const hint = hint_ptr[0..ulen];

    const args = [_][]const u8{ "verify", hint };
    const bytes = runSvalinnCli(&args) catch {
        setError("svalinn_cli verify failed");
        return -2;
    };

    return @intCast(bytes);
}

/// Rotate credential for a given hint.
/// Returns number of bytes in result buffer, or negative error code.
pub export fn vault_mcp_rotate(hint_ptr: [*c]const u8, hint_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (proxy.state != .unlocked) {
        setError("vault is not unlocked");
        return -1;
    }

    if (hint_ptr == null) return -3;

    const ulen: usize = std.math.cast(usize, hint_len) orelse return -3;
    const hint = hint_ptr[0..ulen];

    const args = [_][]const u8{ "rotate", hint };
    const bytes = runSvalinnCli(&args) catch {
        setError("svalinn_cli rotate failed");
        return -2;
    };

    return @intCast(bytes);
}

/// Read the result buffer from the last operation.
/// Copies up to max_len bytes into out_ptr. Returns bytes copied.
pub export fn vault_mcp_read_result(out_ptr: [*c]u8, max_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (out_ptr == null) return -1;
    const umax: usize = std.math.cast(usize, max_len) orelse return -1;
    const copy_len = @min(proxy.result_len, umax);
    @memcpy(out_ptr[0..copy_len], proxy.result_buf[0..copy_len]);
    return @intCast(copy_len);
}

/// Read the last error message. Returns bytes copied.
pub export fn vault_mcp_read_error(out_ptr: [*c]u8, max_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (out_ptr == null) return -1;
    const umax: usize = std.math.cast(usize, max_len) orelse return -1;
    const copy_len = @min(proxy.last_error_len, umax);
    @memcpy(out_ptr[0..copy_len], proxy.last_error[0..copy_len]);
    return @intCast(copy_len);
}

/// Reset vault proxy to initial state (test/debug only).
pub export fn vault_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    proxy = .{};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "vault state transitions" {
    vault_mcp_reset();

    // Initial state is locked
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_state()); // locked = 0

    // Locked -> MfaPending
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_transition(1));
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_state()); // mfa_pending = 1

    // MfaPending -> Unlocked
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_transition(2));
    try std.testing.expectEqual(@as(c_int, 2), vault_mcp_state()); // unlocked = 2

    // Unlocked -> Locked
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_transition(0));
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_state()); // locked = 0
}

test "invalid transitions rejected" {
    vault_mcp_reset();

    // Locked -> Unlocked directly (must go through MfaPending)
    try std.testing.expectEqual(@as(c_int, -2), vault_mcp_transition(2));

    // Locked -> Locked (self-transition not allowed)
    try std.testing.expectEqual(@as(c_int, -2), vault_mcp_transition(0));

    // Go to sealed (terminal state)
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_transition(3)); // locked -> sealed
    // No transitions out of sealed
    try std.testing.expectEqual(@as(c_int, -2), vault_mcp_transition(0));
    try std.testing.expectEqual(@as(c_int, -2), vault_mcp_transition(1));
    try std.testing.expectEqual(@as(c_int, -2), vault_mcp_transition(2));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_can_transition(0, 1)); // locked -> mfa_pending
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_can_transition(1, 2)); // mfa_pending -> unlocked
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_can_transition(1, 0)); // mfa_pending -> locked
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_can_transition(2, 0)); // unlocked -> locked
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_can_transition(2, 3)); // unlocked -> sealed
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_can_transition(0, 3)); // locked -> sealed

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_can_transition(0, 2)); // locked -> unlocked
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_can_transition(3, 0)); // sealed -> locked
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_can_transition(3, 1)); // sealed -> mfa_pending

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_can_transition(99, 0));
}

test "action permissions" {
    vault_mcp_reset();

    // Locked state: only status allowed
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_action_permitted(0)); // execute denied
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_action_permitted(1)); // list denied
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_action_permitted(3)); // status allowed

    // Unlock the vault
    _ = vault_mcp_transition(1); // locked -> mfa_pending
    _ = vault_mcp_transition(2); // mfa_pending -> unlocked

    // Unlocked: all actions allowed
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_action_permitted(0)); // execute
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_action_permitted(1)); // list
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_action_permitted(2)); // rotate
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_action_permitted(3)); // status
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_action_permitted(4)); // verify
}

test "execute requires unlocked vault" {
    vault_mcp_reset();

    // Should fail when locked
    const result = vault_mcp_execute("echo hello", 10, "github.com", 10);
    try std.testing.expectEqual(@as(c_int, -1), result);
}

test "list requires unlocked vault" {
    vault_mcp_reset();
    try std.testing.expectEqual(@as(c_int, -1), vault_mcp_list());
}

test "verify requires unlocked vault" {
    vault_mcp_reset();
    try std.testing.expectEqual(@as(c_int, -1), vault_mcp_verify("github.com", 10));
}

test "rotate requires unlocked vault" {
    vault_mcp_reset();
    try std.testing.expectEqual(@as(c_int, -1), vault_mcp_rotate("github.com", 10));
}
