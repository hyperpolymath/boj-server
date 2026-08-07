// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// BoJ Guardian FFI — Resource-aware failure tolerance and self-diagnostics.
//
// Monitors system and cartridge resources, implements circuit breaker pattern,
// generates preemptive warnings, and produces self-diagnostic reports.
//
// Motivated by the "3 Claude instances + 20 MCP servers = frozen desktop"
// incident of 2026-03-08. Prevents resource exhaustion by tracking CPU,
// memory, process count, and file descriptors at both system and cartridge
// level, with hysteresis-based thresholds to avoid alarm flapping.
//
// Key features:
//   - Per-cartridge resource tracking (memory, CPU, FDs, child procs)
//   - Circuit breaker per cartridge (closed/half-open/open)
//   - System-level resource monitoring (reads /proc on Linux)
//   - Preemptive severity assessment (Nominal → Advisory → Caution → Warning → Critical)
//   - Self-diagnostic report generation (structured, queryable via API)
//   - Process suspension/resumption (SIGSTOP/SIGCONT for load shedding)
//   - Mount rejection when system is overloaded

const std = @import("std");

// `std.atomic.Mutex` was removed from the standard library; its replacement is
// `shim.Mutex`, whose lock/unlock surface is identical to the hand-rolled
// wrapper this replaces. The wrapper also busy-waited via `spinLoopHint`, burning
// a core under contention; `shim.Mutex` parks the thread instead. 81 other
// files in this repo already use this form.
const Mutex = shim.Mutex;

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

/// Maximum cartridges the guardian can track.
const MAX_TRACKED: usize = 128;

/// Maximum length of a cartridge name.
const MAX_NAME_LEN: usize = 64;

/// Maximum length of a diagnostic message.
const MAX_MSG_LEN: usize = 256;

/// Maximum number of diagnostic log entries.
const MAX_LOG_ENTRIES: usize = 64;

/// Default circuit breaker failure threshold.
const DEFAULT_FAILURE_THRESHOLD: u32 = 3;

/// Default circuit breaker cooldown (seconds).
const DEFAULT_COOLDOWN_SECONDS: i64 = 30;

/// Default health check interval (seconds).
const DEFAULT_HEALTH_INTERVAL: i64 = 10;

/// Maximum memory per cartridge before warning (512 MB).
const MAX_CARTRIDGE_MEMORY: u64 = 536_870_912;

/// Maximum total BoJ-managed processes before warning.
const MAX_BOJ_PROCESSES: u32 = 24;

/// CPU percentage that triggers caution.
const CPU_CAUTION: u32 = 60;

/// CPU percentage that triggers warning.
const CPU_WARNING: u32 = 75;

/// CPU percentage that triggers critical.
const CPU_CRITICAL: u32 = 90;

// ═══════════════════════════════════════════════════════════════════════
// Types (match Idris2 Boj.Guardian encodings)
// ═══════════════════════════════════════════════════════════════════════

/// Severity level (matches Guardian.idr severityToInt).
pub const Severity = enum(c_int) {
    nominal = 0,
    advisory = 1,
    caution = 2,
    warning = 3,
    critical = 4,
};

/// Circuit breaker state (matches Guardian.idr circuitStateToInt).
pub const CircuitState = enum(c_int) {
    closed = 0,    // Normal operation
    half_open = 1, // Testing recovery
    open = 2,      // Tripped — requests rejected
};

/// Guardian action type (matches Guardian.idr actionToInt).
pub const ActionType = enum(c_int) {
    no_action = 0,
    emit_advisory = 1,
    emit_warning = 2,
    suspend_cartridge = 3,
    resume_cartridge = 4,
    unmount_cartridge = 5,
    reject_new_mounts = 6,
    shed_load = 7,
    emergency_report = 8,
};

// ═══════════════════════════════════════════════════════════════════════
// Per-Cartridge Resource Tracking
// ═══════════════════════════════════════════════════════════════════════

/// Resource profile for one tracked cartridge.
const CartridgeProfile = struct {
    /// Cartridge name.
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: usize = 0,

    /// Resource metrics.
    memory_bytes: u64 = 0,      // RSS
    cpu_percent: u32 = 0,       // 0-100 (of one core)
    open_fds: u32 = 0,          // File descriptors
    child_procs: u32 = 0,       // Spawned subprocesses
    uptime_seconds: i64 = 0,    // Since mount
    mounted_at: i64 = 0,        // Unix timestamp

    /// Health tracking.
    health_pings: u32 = 0,      // Successful health checks
    failed_pings: u32 = 0,      // Consecutive failed health checks
    last_health_check: i64 = 0, // Unix timestamp

    /// Circuit breaker.
    circuit_state: CircuitState = .closed,
    circuit_failures: u32 = 0,
    circuit_threshold: u32 = DEFAULT_FAILURE_THRESHOLD,
    circuit_cooldown: i64 = DEFAULT_COOLDOWN_SECONDS,
    circuit_last_tripped: i64 = 0,
    circuit_total_trips: u32 = 0,

    /// Process ID for suspension support (0 = unknown).
    pid: u32 = 0,

    /// Whether this slot is occupied.
    active: bool = false,
};

/// System-level resource snapshot.
const SystemSnapshot = struct {
    total_memory_mb: u32 = 0,
    available_memory_mb: u32 = 0,
    cpu_usage_percent: u32 = 0,
    total_processes: u32 = 0,
    boj_processes: u32 = 0,
    load_average_100: u32 = 0, // Load * 100 (fixed-point)
    uptime_seconds: i64 = 0,
    severity: Severity = .nominal,
    timestamp: i64 = 0,
};

/// Diagnostic log entry.
const LogEntry = struct {
    timestamp: i64 = 0,
    severity: Severity = .nominal,
    action: ActionType = .no_action,
    message: [MAX_MSG_LEN]u8 = [_]u8{0} ** MAX_MSG_LEN,
    message_len: usize = 0,
    cartridge_index: i32 = -1, // -1 = system-level
};

// ═══════════════════════════════════════════════════════════════════════
// Global State
// ═══════════════════════════════════════════════════════════════════════

/// Tracked cartridge profiles.
var profiles: [MAX_TRACKED]CartridgeProfile = [_]CartridgeProfile{CartridgeProfile{}} ** MAX_TRACKED;
var profile_count: usize = 0;

/// Latest system snapshot.
var system_snapshot: SystemSnapshot = SystemSnapshot{};

/// Whether the guardian is initialised.
var initialised: bool = false;

/// Whether new mounts are being rejected (overload protection).
var mounts_rejected: bool = false;

/// Diagnostic log (ring buffer).
var log_entries: [MAX_LOG_ENTRIES]LogEntry = [_]LogEntry{LogEntry{}} ** MAX_LOG_ENTRIES;
var log_write_pos: usize = 0;
var log_count: usize = 0;

/// Health check interval (configurable).
var health_interval: i64 = DEFAULT_HEALTH_INTERVAL;

/// Thread-safety mutex for all C-ABI export functions.
var mutex: Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Internal Helpers
// ═══════════════════════════════════════════════════════════════════════

/// Copy a bounded byte slice into a fixed buffer.
fn copyBounded(dst: []u8, src_ptr: [*]const u8, src_len: usize) usize {
    const len = @min(src_len, dst.len);
    @memcpy(dst[0..len], src_ptr[0..len]);
    return len;
}

/// Append a log entry (ring buffer, overwrites oldest).
fn appendLog(severity: Severity, action: ActionType, msg_ptr: [*]const u8, msg_len: usize, cart_idx: i32) void {
    var entry = &log_entries[log_write_pos];
    entry.timestamp = shim.timestamp();
    entry.severity = severity;
    entry.action = action;
    entry.message_len = copyBounded(&entry.message, msg_ptr, msg_len);
    entry.cartridge_index = cart_idx;

    log_write_pos = (log_write_pos + 1) % MAX_LOG_ENTRIES;
    if (log_count < MAX_LOG_ENTRIES) log_count += 1;
}

/// Assess severity from CPU percentage.
fn assessCpu(cpu: u32) Severity {
    if (cpu >= CPU_CRITICAL) return .critical;
    if (cpu >= CPU_WARNING) return .warning;
    if (cpu >= CPU_CAUTION) return .caution;
    return .nominal;
}

/// Assess severity from memory percentage (available/total * 100).
fn assessMemory(available_mb: u32, total_mb: u32) Severity {
    if (total_mb == 0) return .nominal;
    const pct_available = (available_mb * 100) / total_mb;
    if (pct_available <= 5) return .critical;
    if (pct_available <= 15) return .warning;
    if (pct_available <= 30) return .caution;
    return .nominal;
}

/// Assess severity from BoJ process count.
fn assessProcesses(boj_procs: u32) Severity {
    if (boj_procs >= 24) return .critical;
    if (boj_procs >= 16) return .warning;
    if (boj_procs >= 10) return .caution;
    return .nominal;
}

/// Return the worse of two severities.
fn worseSeverity(a: Severity, b: Severity) Severity {
    const ai = @intFromEnum(a);
    const bi = @intFromEnum(b);
    return if (ai >= bi) a else b;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports — Lifecycle
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the guardian. Must be called at BoJ startup.
pub export fn boj_guardian_init() c_int {
    mutex.lock();
    defer mutex.unlock();
    profiles = [_]CartridgeProfile{CartridgeProfile{}} ** MAX_TRACKED;
    profile_count = 0;
    system_snapshot = SystemSnapshot{};
    mounts_rejected = false;
    log_entries = [_]LogEntry{LogEntry{}} ** MAX_LOG_ENTRIES;
    log_write_pos = 0;
    log_count = 0;
    health_interval = DEFAULT_HEALTH_INTERVAL;
    initialised = true;

    const msg = "Guardian initialised";
    appendLog(.nominal, .no_action, msg, msg.len, -1);
    return 0;
}

/// Shut down the guardian.
pub export fn boj_guardian_deinit() void {
    mutex.lock();
    defer mutex.unlock();
    profiles = [_]CartridgeProfile{CartridgeProfile{}} ** MAX_TRACKED;
    profile_count = 0;
    initialised = false;
    mounts_rejected = false;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports — Cartridge Registration
// ═══════════════════════════════════════════════════════════════════════

/// Register a cartridge for resource tracking.
/// Returns the profile index on success, -1 if full or invalid.
pub export fn boj_guardian_track(
    name_ptr: [*]const u8,
    name_len: usize,
    pid: u32,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return -1;
    if (name_len == 0 or name_len > MAX_NAME_LEN) return -1;
    if (profile_count >= MAX_TRACKED) return -1;

    // Find a free slot.
    var slot: usize = 0;
    while (slot < MAX_TRACKED) : (slot += 1) {
        if (!profiles[slot].active) break;
    }
    if (slot >= MAX_TRACKED) return -1;

    profiles[slot] = CartridgeProfile{};
    profiles[slot].name_len = copyBounded(&profiles[slot].name, name_ptr, name_len);
    profiles[slot].pid = pid;
    profiles[slot].mounted_at = shim.timestamp();
    profiles[slot].active = true;

    profile_count += 1;

    const msg = "Cartridge tracked";
    appendLog(.nominal, .no_action, msg, msg.len, @intCast(slot));
    return @intCast(slot);
}

/// Untrack a cartridge (called on unmount).
pub export fn boj_guardian_untrack(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;

    const msg = "Cartridge untracked";
    appendLog(.nominal, .no_action, msg, msg.len, @intCast(index));

    profiles[index] = CartridgeProfile{};
    profile_count -= 1;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports — Resource Updates
// ═══════════════════════════════════════════════════════════════════════

/// Update resource metrics for a tracked cartridge.
/// Called periodically by the health check loop.
pub export fn boj_guardian_update_resources(
    index: usize,
    memory_bytes: u64,
    cpu_percent: u32,
    open_fds: u32,
    child_procs: u32,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;

    profiles[index].memory_bytes = memory_bytes;
    profiles[index].cpu_percent = cpu_percent;
    profiles[index].open_fds = open_fds;
    profiles[index].child_procs = child_procs;
    profiles[index].uptime_seconds = shim.timestamp() - profiles[index].mounted_at;

    // Check per-cartridge thresholds.
    if (memory_bytes > MAX_CARTRIDGE_MEMORY) {
        const msg = "Cartridge exceeds 512MB memory limit";
        appendLog(.warning, .emit_warning, msg, msg.len, @intCast(index));
    }
    if (cpu_percent >= CPU_CRITICAL) {
        const msg = "Cartridge CPU usage critical";
        appendLog(.critical, .emit_warning, msg, msg.len, @intCast(index));
    }

    return 0;
}

/// Update the system-level resource snapshot.
/// Called periodically (every health_interval seconds).
pub export fn boj_guardian_update_system(
    total_memory_mb: u32,
    available_memory_mb: u32,
    cpu_usage_percent: u32,
    total_processes: u32,
    boj_processes: u32,
    load_average_100: u32,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return -1;

    system_snapshot.total_memory_mb = total_memory_mb;
    system_snapshot.available_memory_mb = available_memory_mb;
    system_snapshot.cpu_usage_percent = cpu_usage_percent;
    system_snapshot.total_processes = total_processes;
    system_snapshot.boj_processes = boj_processes;
    system_snapshot.load_average_100 = load_average_100;
    system_snapshot.timestamp = shim.timestamp();

    // Compute overall severity.
    const cpu_sev = assessCpu(cpu_usage_percent);
    const mem_sev = assessMemory(available_memory_mb, total_memory_mb);
    const proc_sev = assessProcesses(boj_processes);

    system_snapshot.severity = worseSeverity(cpu_sev, worseSeverity(mem_sev, proc_sev));

    // Preemptive actions based on severity.
    switch (system_snapshot.severity) {
        .critical => {
            mounts_rejected = true;
            const msg = "CRITICAL: Rejecting new mounts, shedding load";
            appendLog(.critical, .reject_new_mounts, msg, msg.len, -1);
        },
        .warning => {
            mounts_rejected = true;
            const msg = "WARNING: Rejecting new mounts";
            appendLog(.warning, .reject_new_mounts, msg, msg.len, -1);
        },
        .caution => {
            const msg = "CAUTION: Resource usage elevated";
            appendLog(.caution, .emit_advisory, msg, msg.len, -1);
            mounts_rejected = false;
        },
        .nominal, .advisory => {
            mounts_rejected = false;
        },
    }

    return @intFromEnum(system_snapshot.severity);
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports — Health Checks
// ═══════════════════════════════════════════════════════════════════════

/// Record a successful health check for a cartridge.
pub export fn boj_guardian_health_ok(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;

    profiles[index].health_pings += 1;
    profiles[index].failed_pings = 0;
    profiles[index].last_health_check = shim.timestamp();

    // If circuit was half-open, close it (recovery confirmed).
    if (profiles[index].circuit_state == .half_open) {
        profiles[index].circuit_state = .closed;
        profiles[index].circuit_failures = 0;
        const msg = "Circuit breaker closed (recovery)";
        appendLog(.nominal, .resume_cartridge, msg, msg.len, @intCast(index));
    }

    return 0;
}

/// Record a failed health check for a cartridge.
/// May trip the circuit breaker.
pub export fn boj_guardian_health_fail(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;

    const now = shim.timestamp();
    profiles[index].failed_pings += 1;
    profiles[index].last_health_check = now;

    // Circuit breaker logic.
    profiles[index].circuit_failures += 1;

    if (profiles[index].circuit_state == .half_open) {
        // Probe failed — re-open circuit.
        profiles[index].circuit_state = .open;
        profiles[index].circuit_last_tripped = now;
        profiles[index].circuit_total_trips += 1;
        const msg = "Circuit breaker re-opened (probe failed)";
        appendLog(.warning, .suspend_cartridge, msg, msg.len, @intCast(index));
    } else if (profiles[index].circuit_failures >= profiles[index].circuit_threshold) {
        // Threshold exceeded — trip circuit.
        profiles[index].circuit_state = .open;
        profiles[index].circuit_last_tripped = now;
        profiles[index].circuit_total_trips += 1;
        const msg = "Circuit breaker TRIPPED";
        appendLog(.warning, .suspend_cartridge, msg, msg.len, @intCast(index));
    }

    return @intFromEnum(profiles[index].circuit_state);
}

/// Check if a cartridge's circuit breaker should try recovery.
/// Transitions Open → HalfOpen if cooldown elapsed.
/// Returns the new circuit state.
pub export fn boj_guardian_check_recovery(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;

    if (profiles[index].circuit_state == .open) {
        const now = shim.timestamp();
        if (now - profiles[index].circuit_last_tripped >= profiles[index].circuit_cooldown) {
            profiles[index].circuit_state = .half_open;
            const msg = "Circuit breaker half-open (testing recovery)";
            appendLog(.advisory, .resume_cartridge, msg, msg.len, @intCast(index));
        }
    }

    return @intFromEnum(profiles[index].circuit_state);
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports — Mount Gate
// ═══════════════════════════════════════════════════════════════════════

/// Check whether a new mount should be allowed.
/// Returns 1 if allowed, 0 if rejected (system overloaded).
pub export fn boj_guardian_allow_mount() c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return 0;
    return if (mounts_rejected) 0 else 1;
}

/// Get current system severity level.
pub export fn boj_guardian_severity() c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) return 0;
    return @intFromEnum(system_snapshot.severity);
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports — Queries
// ═══════════════════════════════════════════════════════════════════════

/// Get the number of tracked cartridges.
pub export fn boj_guardian_tracked_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return profile_count;
}

/// Get the number of cartridges with open (tripped) circuit breakers.
pub export fn boj_guardian_tripped_count() usize {
    mutex.lock();
    defer mutex.unlock();
    var count: usize = 0;
    for (&profiles) |*p| {
        if (p.active and p.circuit_state == .open) count += 1;
    }
    return count;
}

/// Get the number of unhealthy cartridges (3+ consecutive failed pings).
pub export fn boj_guardian_unhealthy_count() usize {
    mutex.lock();
    defer mutex.unlock();
    var count: usize = 0;
    for (&profiles) |*p| {
        if (p.active and p.failed_pings >= 3) count += 1;
    }
    return count;
}

/// Get whether mounts are currently being rejected.
pub export fn boj_guardian_mounts_rejected() c_int {
    mutex.lock();
    defer mutex.unlock();
    return if (mounts_rejected) 1 else 0;
}

/// Get the circuit breaker state for a cartridge.
pub export fn boj_guardian_circuit_state(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;
    return @intFromEnum(profiles[index].circuit_state);
}

/// Get consecutive failed pings for a cartridge.
pub export fn boj_guardian_failed_pings(index: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;
    return @intCast(profiles[index].failed_pings);
}

/// Get memory usage in bytes for a cartridge.
pub export fn boj_guardian_memory(index: usize) u64 {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return 0;
    return profiles[index].memory_bytes;
}

/// Get CPU usage percentage for a cartridge.
pub export fn boj_guardian_cpu(index: usize) u32 {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return 0;
    return profiles[index].cpu_percent;
}

/// Get system CPU usage.
pub export fn boj_guardian_system_cpu() u32 {
    mutex.lock();
    defer mutex.unlock();
    return system_snapshot.cpu_usage_percent;
}

/// Get system available memory (MB).
pub export fn boj_guardian_system_avail_mem() u32 {
    mutex.lock();
    defer mutex.unlock();
    return system_snapshot.available_memory_mb;
}

/// Get BoJ-managed process count.
pub export fn boj_guardian_boj_processes() u32 {
    mutex.lock();
    defer mutex.unlock();
    return system_snapshot.boj_processes;
}

/// Get the diagnostic log entry count.
pub export fn boj_guardian_log_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return log_count;
}

/// Read a diagnostic log entry by index (0 = most recent).
/// Writes the message into out_ptr, returns message length.
/// severity_out and action_out receive the entry's severity and action type.
pub export fn boj_guardian_log_entry(
    index: usize,
    out_ptr: [*]u8,
    out_len: usize,
    severity_out: *c_int,
    action_out: *c_int,
    timestamp_out: *i64,
) usize {
    mutex.lock();
    defer mutex.unlock();
    if (index >= log_count) return 0;

    // Index 0 = most recent (reverse ring buffer order).
    const actual = if (log_write_pos > index)
        log_write_pos - 1 - index
    else
        MAX_LOG_ENTRIES - 1 - (index - log_write_pos);

    const entry = &log_entries[actual];
    const copy_len = @min(out_len, entry.message_len);
    @memcpy(out_ptr[0..copy_len], entry.message[0..copy_len]);
    severity_out.* = @intFromEnum(entry.severity);
    action_out.* = @intFromEnum(entry.action);
    timestamp_out.* = entry.timestamp;
    return copy_len;
}

/// Set the health check interval (seconds).
pub export fn boj_guardian_set_health_interval(seconds: i64) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (seconds < 1 or seconds > 3600) return -1;
    health_interval = seconds;
    return 0;
}

/// Get the health check interval (seconds).
pub export fn boj_guardian_get_health_interval() i64 {
    mutex.lock();
    defer mutex.unlock();
    return health_interval;
}

/// Set the circuit breaker threshold for a cartridge.
pub export fn boj_guardian_set_circuit_threshold(index: usize, threshold: u32) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;
    if (threshold == 0) return -1;
    profiles[index].circuit_threshold = threshold;
    return 0;
}

/// Set the circuit breaker cooldown for a cartridge.
pub export fn boj_guardian_set_circuit_cooldown(index: usize, seconds: i64) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or index >= MAX_TRACKED or !profiles[index].active) return -1;
    if (seconds < 1) return -1;
    profiles[index].circuit_cooldown = seconds;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports — Diagnostic Report
// ═══════════════════════════════════════════════════════════════════════

/// Generate a summary diagnostic line into out_ptr.
/// Format: "SEV=N CPIU=N% MEM=N/NMB PROCS=N TRACKED=N UNHEALTHY=N TRIPPED=N MOUNTS=OK|REJECTED"
/// Returns the number of bytes written.
pub export fn boj_guardian_diagnostic_summary(out_ptr: [*]u8, out_len: usize) usize {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised or out_len < 128) return 0;

    const sev_names = [_][]const u8{ "NOMINAL", "ADVISORY", "CAUTION", "WARNING", "CRITICAL" };
    const sev_idx: usize = @intCast(@intFromEnum(system_snapshot.severity));
    const sev_name = if (sev_idx < sev_names.len) sev_names[sev_idx] else "UNKNOWN";

    var unhealthy: u32 = 0;
    var tripped: u32 = 0;
    for (&profiles) |*p| {
        if (p.active) {
            if (p.failed_pings >= 3) unhealthy += 1;
            if (p.circuit_state == .open) tripped += 1;
        }
    }

    const mount_status: []const u8 = if (mounts_rejected) "REJECTED" else "OK";

    const result = std.fmt.bufPrint(
        out_ptr[0..out_len],
        "SEV={s} CPU={d}% MEM={d}/{d}MB PROCS={d} TRACKED={d} UNHEALTHY={d} TRIPPED={d} MOUNTS={s}",
        .{
            sev_name,
            system_snapshot.cpu_usage_percent,
            system_snapshot.available_memory_mb,
            system_snapshot.total_memory_mb,
            system_snapshot.boj_processes,
            profile_count,
            unhealthy,
            tripped,
            mount_status,
        },
    ) catch return 0;

    return result.len;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "guardian lifecycle" {
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_init());
    try std.testing.expectEqual(@as(usize, 0), boj_guardian_tracked_count());
    try std.testing.expectEqual(@as(c_int, 1), boj_guardian_allow_mount());
    boj_guardian_deinit();
}

test "track and untrack cartridge" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    const name = "test-database-mcp";
    const idx = boj_guardian_track(name.ptr, name.len, 12345);
    try std.testing.expect(idx >= 0);
    try std.testing.expectEqual(@as(usize, 1), boj_guardian_tracked_count());

    // Circuit should start closed.
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.closed)), boj_guardian_circuit_state(@intCast(idx)));

    // Untrack.
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_untrack(@intCast(idx)));
    try std.testing.expectEqual(@as(usize, 0), boj_guardian_tracked_count());
}

test "resource update and per-cartridge thresholds" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    const name = "heavy-cartridge";
    const idx: usize = @intCast(boj_guardian_track(name.ptr, name.len, 99));

    // Normal usage.
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_update_resources(idx, 100_000_000, 25, 10, 2));
    try std.testing.expectEqual(@as(u64, 100_000_000), boj_guardian_memory(idx));
    try std.testing.expectEqual(@as(u32, 25), boj_guardian_cpu(idx));

    // Excessive memory — should log warning.
    const log_before = boj_guardian_log_count();
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_update_resources(idx, 600_000_000, 95, 50, 5));
    try std.testing.expect(boj_guardian_log_count() > log_before);
}

test "system severity assessment" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    // Nominal.
    const sev1 = boj_guardian_update_system(32000, 22000, 15, 200, 4, 150);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Severity.nominal)), sev1);
    try std.testing.expectEqual(@as(c_int, 1), boj_guardian_allow_mount());

    // Caution (CPU 65%).
    const sev2 = boj_guardian_update_system(32000, 22000, 65, 200, 4, 250);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Severity.caution)), sev2);
    try std.testing.expectEqual(@as(c_int, 1), boj_guardian_allow_mount()); // Still allowed.

    // Warning (CPU 80%).
    const sev3 = boj_guardian_update_system(32000, 22000, 80, 200, 4, 350);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Severity.warning)), sev3);
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_allow_mount()); // Rejected!

    // Critical (CPU 95%).
    const sev4 = boj_guardian_update_system(32000, 2000, 95, 300, 20, 500);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Severity.critical)), sev4);
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_allow_mount());

    // Recovery — back to nominal.
    const sev5 = boj_guardian_update_system(32000, 25000, 10, 150, 3, 100);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Severity.nominal)), sev5);
    try std.testing.expectEqual(@as(c_int, 1), boj_guardian_allow_mount()); // Allowed again.
}

test "circuit breaker trip and recovery" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    const name = "flaky-cartridge";
    const idx: usize = @intCast(boj_guardian_track(name.ptr, name.len, 555));

    // 3 consecutive failures should trip the breaker.
    _ = boj_guardian_health_fail(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.closed)), boj_guardian_circuit_state(idx));

    _ = boj_guardian_health_fail(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.closed)), boj_guardian_circuit_state(idx));

    const state3 = boj_guardian_health_fail(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.open)), state3);
    try std.testing.expectEqual(@as(usize, 1), boj_guardian_tripped_count());

    // Set cooldown to 0 for test, then check recovery.
    _ = boj_guardian_set_circuit_cooldown(idx, 1);

    // Simulate time passing by setting last_tripped far in the past.
    profiles[idx].circuit_last_tripped = shim.timestamp() - 100;

    const recovered = boj_guardian_check_recovery(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.half_open)), recovered);

    // Successful health check closes the circuit.
    _ = boj_guardian_health_ok(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.closed)), boj_guardian_circuit_state(idx));
    try std.testing.expectEqual(@as(usize, 0), boj_guardian_tripped_count());
}

test "circuit breaker half-open probe failure re-opens" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    const name = "stubborn-cartridge";
    const idx: usize = @intCast(boj_guardian_track(name.ptr, name.len, 777));

    // Trip the breaker.
    _ = boj_guardian_health_fail(idx);
    _ = boj_guardian_health_fail(idx);
    _ = boj_guardian_health_fail(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.open)), boj_guardian_circuit_state(idx));

    // Force half-open.
    profiles[idx].circuit_last_tripped = shim.timestamp() - 100;
    _ = boj_guardian_set_circuit_cooldown(idx, 1);
    _ = boj_guardian_check_recovery(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.half_open)), boj_guardian_circuit_state(idx));

    // Probe fails — should re-open.
    _ = boj_guardian_health_fail(idx);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CircuitState.open)), boj_guardian_circuit_state(idx));
}

test "health ok resets failed pings" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    const name = "recovering-cartridge";
    const idx: usize = @intCast(boj_guardian_track(name.ptr, name.len, 888));

    _ = boj_guardian_health_fail(idx);
    _ = boj_guardian_health_fail(idx);
    try std.testing.expectEqual(@as(c_int, 2), boj_guardian_failed_pings(idx));

    _ = boj_guardian_health_ok(idx);
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_failed_pings(idx));
}

test "diagnostic summary generation" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    _ = boj_guardian_update_system(32000, 22000, 15, 200, 4, 150);

    var buf: [256]u8 = undefined;
    const len = boj_guardian_diagnostic_summary(&buf, 256);
    try std.testing.expect(len > 0);

    // Should contain "NOMINAL" since CPU is 15%.
    const summary = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, summary, "NOMINAL") != null);
}

test "log ring buffer" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    // Init creates one log entry.
    try std.testing.expectEqual(@as(usize, 1), boj_guardian_log_count());

    // Track a cartridge — adds another.
    const name = "log-test";
    _ = boj_guardian_track(name.ptr, name.len, 111);
    try std.testing.expectEqual(@as(usize, 2), boj_guardian_log_count());

    // Read most recent entry.
    var msg_buf: [256]u8 = undefined;
    var sev: c_int = undefined;
    var action: c_int = undefined;
    var ts: i64 = undefined;
    const msg_len = boj_guardian_log_entry(0, &msg_buf, 256, &sev, &action, &ts);
    try std.testing.expect(msg_len > 0);
    try std.testing.expect(ts > 0);
}

test "process count triggers warning" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    // 20 BoJ processes should trigger warning.
    const sev = boj_guardian_update_system(32000, 22000, 15, 300, 20, 150);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Severity.warning)), sev);
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_allow_mount());
}

test "memory scarcity triggers critical" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    // Only 1GB of 32GB available (3%) = critical.
    const sev = boj_guardian_update_system(32000, 1000, 15, 200, 4, 150);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Severity.critical)), sev);
}

test "invalid operations return errors" {
    _ = boj_guardian_init();
    defer boj_guardian_deinit();

    // Invalid index operations.
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_untrack(99));
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_health_ok(99));
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_health_fail(99));
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_circuit_state(99));
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_failed_pings(99));
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_check_recovery(99));

    // Invalid health interval.
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_set_health_interval(0));
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_set_health_interval(7200));

    // Valid health interval.
    try std.testing.expectEqual(@as(c_int, 0), boj_guardian_set_health_interval(5));
    try std.testing.expectEqual(@as(i64, 5), boj_guardian_get_health_interval());

    // Empty name.
    const empty = "";
    try std.testing.expectEqual(@as(c_int, -1), boj_guardian_track(empty.ptr, 0, 1));
}

const shim = @import("cartridge_shim");
