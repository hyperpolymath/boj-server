// SPDX-License-Identifier: MPL-2.0
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

/// Maximum audit log entries retained in memory (ring buffer).
const MAX_AUDIT_ENTRIES = 128;

/// Maximum commands in the AI agent allowlist.
const MAX_ALLOWLIST = 64;

/// A single audit log entry recording a vault operation.
const AuditEntry = struct {
    timestamp: i64 = 0,
    action: VaultAction = .status,
    hint_buf: [128]u8 = undefined,
    hint_len: usize = 0,
    result_code: c_int = 0,
    agent_buf: [64]u8 = undefined,
    agent_len: usize = 0,
};

/// A command pattern in the AI agent allowlist.
/// Commands must match one of these prefixes to be executed via vault/execute.
const AllowlistEntry = struct {
    pattern_buf: [256]u8 = undefined,
    pattern_len: usize = 0,
    active: bool = false,
};

/// Thread-safe vault proxy state.
const VaultProxy = struct {
    state: VaultState = .locked,
    result_buf: [RESULT_BUF_SIZE]u8 = undefined,
    result_len: usize = 0,
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
    credential_count: u32 = 0,
    last_access_epoch: i64 = 0,

    // Audit ring buffer
    audit: [MAX_AUDIT_ENTRIES]AuditEntry = [_]AuditEntry{.{}} ** MAX_AUDIT_ENTRIES,
    audit_head: usize = 0,
    audit_count: usize = 0,

    // Command allowlist for AI agents
    allowlist: [MAX_ALLOWLIST]AllowlistEntry = [_]AllowlistEntry{.{}} ** MAX_ALLOWLIST,
    allowlist_count: usize = 0,
    allowlist_enforced: bool = false,
};

var proxy: VaultProxy = .{};
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Run svalinn_cli with the given arguments and capture stdout.
/// Returns the number of bytes written to proxy.result_buf, or error.
fn runSvalinnCli(args: []const []const u8) !usize {
    // Build argv as a fixed-size buffer: svalinn_cli + up to 15 arguments.
    const MAX_ARGS = 16;
    var argv_buf: [MAX_ARGS][]const u8 = undefined;
    argv_buf[0] = SVALINN_CLI;
    if (args.len >= MAX_ARGS) return error.TooManyArguments;
    for (args, 0..) |arg, i| {
        argv_buf[1 + i] = arg;
    }
    const argv_slice = argv_buf[0 .. 1 + args.len];

    var child = std.process.Child.init(argv_slice, std.heap.page_allocator);
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

    // Check command allowlist before executing
    if (!isCommandAllowed(command)) {
        setError("command not in allowlist");
        recordAudit(.execute, hint, -4, "ai-agent");
        return -4;
    }

    const args = [_][]const u8{ "get", hint, "--exec", command };
    const bytes = runSvalinnCli(&args) catch {
        setError("svalinn_cli execution failed");
        recordAudit(.execute, hint, -2, "ai-agent");
        return -2;
    };

    recordAudit(.execute, hint, @intCast(bytes), "ai-agent");
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

// ---------------------------------------------------------------------------
// Internal helpers — audit + allowlist
// ---------------------------------------------------------------------------

/// Record an audit entry in the ring buffer.
fn recordAudit(action: VaultAction, hint: []const u8, result_code: c_int, agent: []const u8) void {
    const idx = proxy.audit_head;
    var entry = &proxy.audit[idx];

    entry.timestamp = std.time.timestamp();
    entry.action = action;
    entry.result_code = result_code;

    const h_len = @min(hint.len, entry.hint_buf.len);
    @memcpy(entry.hint_buf[0..h_len], hint[0..h_len]);
    entry.hint_len = h_len;

    const a_len = @min(agent.len, entry.agent_buf.len);
    @memcpy(entry.agent_buf[0..a_len], agent[0..a_len]);
    entry.agent_len = a_len;

    proxy.audit_head = (proxy.audit_head + 1) % MAX_AUDIT_ENTRIES;
    if (proxy.audit_count < MAX_AUDIT_ENTRIES) proxy.audit_count += 1;
}

/// Check if a command is allowed by the allowlist.
/// Returns true if allowlist is not enforced, or if command matches a prefix.
fn isCommandAllowed(command: []const u8) bool {
    if (!proxy.allowlist_enforced) return true;
    if (proxy.allowlist_count == 0) return false;

    for (proxy.allowlist[0..proxy.allowlist_count]) |entry| {
        if (!entry.active) continue;
        const pat = entry.pattern_buf[0..entry.pattern_len];
        if (command.len >= pat.len and std.mem.eql(u8, command[0..pat.len], pat)) {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// C-ABI exports — audit log
// ---------------------------------------------------------------------------

/// Get the number of audit entries available.
pub export fn vault_mcp_audit_count() c_int {
    mutex.lock();
    defer mutex.unlock();
    return @intCast(proxy.audit_count);
}

/// Read an audit entry as JSON into the result buffer.
/// Index 0 = most recent. Returns bytes written, or -1 if out of range.
pub export fn vault_mcp_audit_entry(index: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const uidx: usize = std.math.cast(usize, index) orelse return -1;
    if (uidx >= proxy.audit_count) return -1;

    // Walk backwards from head
    const real_idx = (proxy.audit_head + MAX_AUDIT_ENTRIES - 1 - uidx) % MAX_AUDIT_ENTRIES;
    const entry = &proxy.audit[real_idx];

    const hint = entry.hint_buf[0..entry.hint_len];
    const agent = entry.agent_buf[0..entry.agent_len];
    const action_str: []const u8 = switch (entry.action) {
        .execute => "execute",
        .list => "list",
        .rotate => "rotate",
        .status => "status",
        .verify => "verify",
    };
    const result_str: []const u8 = if (entry.result_code >= 0) "ok" else "error";

    // Format as JSON line
    const written = std.fmt.bufPrint(&proxy.result_buf, "{{\"timestamp\":{d},\"action\":\"{s}\",\"credential_hint\":\"{s}\",\"result\":\"{s}\",\"agent\":\"{s}\"}}", .{
        entry.timestamp,
        action_str,
        hint,
        result_str,
        agent,
    }) catch return -2;

    proxy.result_len = written.len;
    return @intCast(written.len);
}

// ---------------------------------------------------------------------------
// C-ABI exports — command allowlist
// ---------------------------------------------------------------------------

/// Add a command prefix to the AI agent allowlist.
/// Returns 0 on success, -1 if full, -3 if null/too long.
pub export fn vault_mcp_allowlist_add(pattern_ptr: [*c]const u8, pattern_len: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (pattern_ptr == null) return -3;
    const ulen: usize = std.math.cast(usize, pattern_len) orelse return -3;
    if (ulen > 256) return -3;
    if (proxy.allowlist_count >= MAX_ALLOWLIST) return -1;

    const pattern = pattern_ptr[0..ulen];
    var entry = &proxy.allowlist[proxy.allowlist_count];
    @memcpy(entry.pattern_buf[0..ulen], pattern);
    entry.pattern_len = ulen;
    entry.active = true;
    proxy.allowlist_count += 1;
    return 0;
}

/// Enable or disable allowlist enforcement.
/// When enabled (1), vault/execute rejects commands not matching any prefix.
pub export fn vault_mcp_allowlist_enforce(enabled: c_int) void {
    mutex.lock();
    defer mutex.unlock();
    proxy.allowlist_enforced = enabled != 0;
}

/// Get allowlist enforcement status. Returns 1 (enforced) or 0 (open).
pub export fn vault_mcp_allowlist_status() c_int {
    mutex.lock();
    defer mutex.unlock();
    return if (proxy.allowlist_enforced) 1 else 0;
}

/// Get the number of allowlist entries.
pub export fn vault_mcp_allowlist_count() c_int {
    mutex.lock();
    defer mutex.unlock();
    return @intCast(proxy.allowlist_count);
}

/// Reset vault proxy to initial state (test/debug only).
pub export fn vault_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    proxy = .{};
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "vault-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "vault_execute"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vault_list"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vault_status"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vault_verify"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "vault_rotate"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

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

test "audit ring buffer" {
    vault_mcp_reset();

    // Initially empty
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_audit_count());

    // Execute when locked produces an audit entry (from the -1 error path)
    _ = vault_mcp_execute("echo hello", 10, "github.com", 10);
    // Note: the -1 path (not unlocked) doesn't call recordAudit in current impl,
    // so audit count should still be 0 from that path.
    // But once unlocked with allowlist enforced and blocked, it does record.

    // Enable allowlist enforcement with no entries (blocks everything)
    vault_mcp_allowlist_enforce(1);
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_allowlist_status());

    // Unlock the vault
    _ = vault_mcp_transition(1); // locked -> mfa_pending
    _ = vault_mcp_transition(2); // mfa_pending -> unlocked

    // Execute should be blocked by allowlist and audited
    const result = vault_mcp_execute("echo hello", 10, "github.com", 10);
    try std.testing.expectEqual(@as(c_int, -4), result);

    // Should now have 1 audit entry
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_audit_count());

    // Read the audit entry
    const entry_bytes = vault_mcp_audit_entry(0);
    try std.testing.expect(entry_bytes > 0);
}

test "allowlist enforcement" {
    vault_mcp_reset();

    // Add "git " prefix to allowlist
    try std.testing.expectEqual(@as(c_int, 0), vault_mcp_allowlist_add("git ", 4));
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_allowlist_count());

    // Enable enforcement
    vault_mcp_allowlist_enforce(1);
    try std.testing.expectEqual(@as(c_int, 1), vault_mcp_allowlist_status());

    // Unlock vault
    _ = vault_mcp_transition(1);
    _ = vault_mcp_transition(2);

    // "rm -rf" should be blocked (doesn't match "git " prefix)
    const blocked = vault_mcp_execute("rm -rf /", 8, "github.com", 10);
    try std.testing.expectEqual(@as(c_int, -4), blocked);

    // "git push" would try to execute (match found) but fail because
    // svalinn_cli isn't available in test — returns -2 (CLI failed)
    const allowed = vault_mcp_execute("git push", 8, "github.com", 10);
    try std.testing.expectEqual(@as(c_int, -2), allowed);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns vault-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("vault-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "vault_execute",
        "vault_list",
        "vault_status",
        "vault_verify",
        "vault_rotate",
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
    const rc = boj_cartridge_invoke("vault_execute", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
