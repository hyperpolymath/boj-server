// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Cloud-MCP Cartridge — Zig FFI bridge for multi-cloud provider operations.
//
// Implements the provider session state machine from SafeCloud.idr.
// Ensures no operation can execute on an unauthenticated provider,
// and tracks credential lifecycle to prevent leaks.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match CloudMcp.SafeCloud encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    operating = 2,
    auth_error = 3,
};

pub const CloudProvider = enum(c_int) {
    aws = 1,
    gcloud = 2,
    azure = 3,
    digital_ocean = 4,
    verpex = 5,
    cloudflare = 6,
    vercel = 7,
    custom = 99,
};

/// Cloudflare resource types — mirrors `CloudMcp.SafeCloud.CloudflareResource`
/// + `cfResourceToInt` encoding. Declared here so `iseriser abi-verify` can
/// structurally check the encoding against the Idris2 source.
///
/// Note: the snake_case variants follow the iseriser converter's current
/// output for multi-cap Idris2 names (e.g. `CfKVNamespace → cf_kvnamespace`,
/// `CfDNSZone → cf_dnszone`). When iseriser#18 lands a smarter multi-cap
/// normaliser, these names may be canonicalised to e.g. `cf_kv_namespace`.
pub const CloudflareResource = enum(c_int) {
    cf_worker = 1,
    cf_d1_database = 2,
    cf_kvnamespace = 3,
    cf_r2_bucket = 4,
    cf_dnszone = 5,
    cf_dnsrecord = 6,
    cf_pages_project = 7,
};

/// Vercel resource types — mirrors `CloudMcp.SafeCloud.VercelResource`
/// + `vclResourceToInt` encoding.
pub const VercelResource = enum(c_int) {
    vcl_project = 1,
    vcl_deployment = 2,
    vcl_domain = 3,
    vcl_env_var = 4,
    vcl_serverless_function = 5,
};

// ═══════════════════════════════════════════════════════════════════════
// Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;

const RESULT_BUF_SIZE: usize = 4096;

const CredentialKind = enum {
    none,
    bearer_token,
    api_key,
};

const SessionSlot = struct {
    active: bool,
    state: SessionState,
    provider: CloudProvider,
    cred_kind: CredentialKind = .none,
    cred_hash: u64 = 0, // FNV hash of credential — never store plaintext
    result_buf: [RESULT_BUF_SIZE]u8 = [_]u8{0} ** RESULT_BUF_SIZE,
    result_len: usize = 0,
};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{.{
    .active = false,
    .state = .unauthenticated,
    .provider = .aws,
    .cred_kind = .none,
    .cred_hash = 0,
    .result_buf = [_]u8{0} ** RESULT_BUF_SIZE,
    .result_len = 0,
}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition (matches Idris2 canTransition).
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .operating or to == .unauthenticated,
        .operating => to == .authenticated or to == .auth_error,
        .auth_error => to == .unauthenticated,
    };
}

/// Authenticate with a provider. Returns slot index or -1 on failure.
pub export fn cloud_authenticate(provider: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions, 0..) |*slot, i| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            slot.provider = @enumFromInt(provider);
            return @intCast(i);
        }
    }
    return -1; // No slots available
}

/// Logout from a provider session by slot index.
pub export fn cloud_logout(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .unauthenticated)) return -2;

    sessions[idx].active = false;
    sessions[idx].state = .unauthenticated;
    return 0;
}

/// Begin an operation (transition Authenticated -> Operating).
pub export fn cloud_begin_operation(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .operating)) return -2;

    sessions[idx].state = .operating;
    return 0;
}

/// End an operation (transition Operating -> Authenticated).
pub export fn cloud_end_operation(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    if (!isValidTransition(sessions[idx].state, .authenticated)) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

/// Get the state of a session.
pub export fn cloud_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return @intFromEnum(SessionState.unauthenticated);
    return @intFromEnum(sessions[idx].state);
}

/// Validate a state transition (C-ABI export).
pub export fn cloud_can_transition(from: c_int, to: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const f: SessionState = @enumFromInt(from);
    const t: SessionState = @enumFromInt(to);
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Reset all sessions (for testing).
pub export fn cloud_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*slot| {
        slot.active = false;
        slot.state = .unauthenticated;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the cloud-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_init() c_int {
    cloud_reset();
    return 0;
}

/// Deinitialise the cloud-mcp cartridge. Resets all session slots.
pub export fn boj_cartridge_deinit() void {
    cloud_reset();
}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "cloud-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 dispatch (boj_cartridge_invoke, 5th standard symbol)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

/// Dispatch the cartridge.json MCP tools. Grade D Alpha — each arm
/// returns a stub JSON body shaped to the tool's intended response.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "cloud_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cloud_logout"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cloud_state"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "cloud_execute"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Vercel Provider (provider code 7)
// Grade D Alpha — stub implementations
// Real API: https://api.vercel.com/v{version}/{endpoint}
// Auth: Authorization: Bearer {token}
// ═══════════════════════════════════════════════════════════════════════

/// Issue a Vercel API request (Grade D Alpha stub).
/// Real implementation would hit https://api.vercel.com/v{version}/{endpoint}
/// with header: Authorization: Bearer {token}
fn vercelRequest(token: []const u8, endpoint: []const u8, method: []const u8) void {
    // Grade D Alpha stub — log intent, no network I/O
    _ = token;
    _ = endpoint;
    _ = method;
}

/// Write a JSON stub response into a session's result buffer.
fn writeVercelResult(slot: *SessionSlot, endpoint: []const u8, method: []const u8) void {
    const prefix = "{\"provider\":\"vercel\",\"endpoint\":\"";
    const mid1 = "\",\"method\":\"";
    const mid2 = "\",\"status\":\"stub\",\"note\":\"Grade D Alpha\"}";

    var pos: usize = 0;
    const parts = [_][]const u8{ prefix, endpoint, mid1, method, mid2 };
    for (parts) |part| {
        if (pos + part.len > RESULT_BUF_SIZE) break;
        @memcpy(slot.result_buf[pos .. pos + part.len], part);
        pos += part.len;
    }
    slot.result_len = pos;
}

/// Validate that a slot is active, authenticated, and bound to the Vercel provider.
fn validateVercelSlot(slot_idx: c_int) ?usize {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return null;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return null;
    if (sessions[idx].provider != .vercel) return null;
    if (sessions[idx].state != .authenticated) return null;
    return idx;
}

/// Set credentials on a Vercel session slot.
pub export fn cloud_vercel_set_credentials(slot_idx: c_int, token_ptr: [*]const u8, token_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    sessions[idx].cred_kind = .bearer_token;
    sessions[idx].cred_hash = std.hash.Fnv1a_64.hash(token_ptr[0..token_len]);
    return 0;
}

/// List Vercel projects.
pub export fn cloud_vercel_list_projects(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    vercelRequest(&.{}, "v9/projects", "GET");
    writeVercelResult(&sessions[idx], "v9/projects", "GET");
    return 0;
}

/// Get a specific Vercel project by name.
pub export fn cloud_vercel_get_project(slot_idx: c_int, name_ptr: [*]const u8, name_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    _ = name_ptr;
    _ = name_len;
    vercelRequest(&.{}, "v9/projects/{name}", "GET");
    writeVercelResult(&sessions[idx], "v9/projects/{name}", "GET");
    return 0;
}

/// List Vercel deployments.
pub export fn cloud_vercel_list_deployments(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    vercelRequest(&.{}, "v6/deployments", "GET");
    writeVercelResult(&sessions[idx], "v6/deployments", "GET");
    return 0;
}

/// Get a specific Vercel deployment by ID.
pub export fn cloud_vercel_get_deployment(slot_idx: c_int, id_ptr: [*]const u8, id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    _ = id_ptr;
    _ = id_len;
    vercelRequest(&.{}, "v13/deployments/{id}", "GET");
    writeVercelResult(&sessions[idx], "v13/deployments/{id}", "GET");
    return 0;
}

/// List Vercel domains.
pub export fn cloud_vercel_list_domains(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    vercelRequest(&.{}, "v5/domains", "GET");
    writeVercelResult(&sessions[idx], "v5/domains", "GET");
    return 0;
}

/// List environment variables for a Vercel project.
pub export fn cloud_vercel_list_env_vars(slot_idx: c_int, project_ptr: [*]const u8, project_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    _ = project_ptr;
    _ = project_len;
    vercelRequest(&.{}, "v9/projects/{project}/env", "GET");
    writeVercelResult(&sessions[idx], "v9/projects/{project}/env", "GET");
    return 0;
}

/// Get deployment logs for a Vercel deployment.
pub export fn cloud_vercel_deployment_logs(slot_idx: c_int, id_ptr: [*]const u8, id_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    _ = id_ptr;
    _ = id_len;
    vercelRequest(&.{}, "v2/deployments/{id}/events", "GET");
    writeVercelResult(&sessions[idx], "v2/deployments/{id}/events", "GET");
    return 0;
}

/// List serverless functions for a Vercel deployment.
pub export fn cloud_vercel_list_functions(slot_idx: c_int, deployment_ptr: [*]const u8, deployment_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVercelSlot(slot_idx) orelse return -1;
    _ = deployment_ptr;
    _ = deployment_len;
    vercelRequest(&.{}, "v1/deployments/{id}/functions", "GET");
    writeVercelResult(&sessions[idx], "v1/deployments/{id}/functions", "GET");
    return 0;
}

/// Read the result buffer for a session slot. Returns length or -1 on error.
pub export fn cloud_vercel_read_result(slot_idx: c_int, out_ptr: [*]u8, out_cap: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    const len = @min(sessions[idx].result_len, out_cap);
    @memcpy(out_ptr[0..len], sessions[idx].result_buf[0..len]);
    return @intCast(len);
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "authenticate and logout" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.aws));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), cloud_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), cloud_logout(slot));
}

test "cannot operate on unauthenticated" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.gcloud));
    _ = cloud_logout(slot);
    // Should fail — can't begin operation on unauthenticated session
    try std.testing.expectEqual(@as(c_int, -1), cloud_begin_operation(slot));
}

test "operation lifecycle" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.azure));
    try std.testing.expectEqual(@as(c_int, 0), cloud_begin_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.operating)), cloud_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), cloud_end_operation(slot));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), cloud_state(slot));
    try std.testing.expectEqual(@as(c_int, 0), cloud_logout(slot));
}

test "cannot double-logout" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.digital_ocean));
    _ = cloud_logout(slot);
    // Second logout should fail — already unauthenticated
    try std.testing.expectEqual(@as(c_int, -1), cloud_logout(slot));
}

test "cannot logout while operating" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.aws));
    _ = cloud_begin_operation(slot);
    // Cannot logout directly from operating — must end operation first
    try std.testing.expectEqual(@as(c_int, -2), cloud_logout(slot));
}

test "state transition validation" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(1, 2)); // auth -> operating
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(2, 1)); // operating -> auth
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(1, 0)); // auth -> unauth
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(2, 3)); // operating -> error
    try std.testing.expectEqual(@as(c_int, 1), cloud_can_transition(3, 0)); // error -> unauth
    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), cloud_can_transition(0, 2)); // unauth -> operating
    try std.testing.expectEqual(@as(c_int, 0), cloud_can_transition(2, 0)); // operating -> unauth
}

test "max sessions enforced" {
    cloud_reset();
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = cloud_authenticate(@intFromEnum(CloudProvider.aws));
        try std.testing.expect(s.* >= 0);
    }
    // Next authenticate should fail
    try std.testing.expectEqual(@as(c_int, -1), cloud_authenticate(@intFromEnum(CloudProvider.aws)));
    // Free one and retry
    _ = cloud_logout(slots[0]);
    try std.testing.expect(cloud_authenticate(@intFromEnum(CloudProvider.aws)) >= 0);
}

// ═══════════════════════════════════════════════════════════════════════
// Vercel Provider Tests
// ═══════════════════════════════════════════════════════════════════════

test "vercel auth and credential storage" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.vercel));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), cloud_state(slot));
    // Set credentials (bearer token)
    const token = "vcel_test_token_abc123";
    try std.testing.expectEqual(@as(c_int, 0), cloud_vercel_set_credentials(slot, token.ptr, token.len));
    try std.testing.expectEqual(@as(c_int, 0), cloud_logout(slot));
}

test "vercel list projects and list deployments" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.vercel));
    try std.testing.expect(slot >= 0);
    // list_projects should succeed on an authenticated Vercel slot
    try std.testing.expectEqual(@as(c_int, 0), cloud_vercel_list_projects(slot));
    // Read the result buffer to verify JSON stub was written
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    const len = cloud_vercel_read_result(slot, &buf, buf.len);
    try std.testing.expect(len > 0);
    // list_deployments should also succeed
    try std.testing.expectEqual(@as(c_int, 0), cloud_vercel_list_deployments(slot));
    // get_project should succeed
    const name = "my-project";
    try std.testing.expectEqual(@as(c_int, 0), cloud_vercel_get_project(slot, name.ptr, name.len));
    _ = cloud_logout(slot);
}

test "vercel domains, env vars, logs, and functions" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.vercel));
    try std.testing.expect(slot >= 0);
    // list_domains
    try std.testing.expectEqual(@as(c_int, 0), cloud_vercel_list_domains(slot));
    // list_env_vars
    const proj = "my-project";
    try std.testing.expectEqual(@as(c_int, 0), cloud_vercel_list_env_vars(slot, proj.ptr, proj.len));
    // deployment_logs
    const dep_id = "dpl_abc123";
    try std.testing.expectEqual(@as(c_int, 0), cloud_vercel_deployment_logs(slot, dep_id.ptr, dep_id.len));
    // list_functions
    try std.testing.expectEqual(@as(c_int, 0), cloud_vercel_list_functions(slot, dep_id.ptr, dep_id.len));
    _ = cloud_logout(slot);
}

test "vercel wrong-provider rejection" {
    cloud_reset();
    // Authenticate as AWS, then try Vercel operations — should fail
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.aws));
    try std.testing.expect(slot >= 0);
    // All Vercel operations should return -1 (wrong provider)
    try std.testing.expectEqual(@as(c_int, -1), cloud_vercel_list_projects(slot));
    try std.testing.expectEqual(@as(c_int, -1), cloud_vercel_list_deployments(slot));
    try std.testing.expectEqual(@as(c_int, -1), cloud_vercel_list_domains(slot));
    const token = "vcel_test";
    try std.testing.expectEqual(@as(c_int, -1), cloud_vercel_set_credentials(slot, token.ptr, token.len));
    _ = cloud_logout(slot);
}

// ═══════════════════════════════════════════════════════════════════════
// Cloudflare Provider (provider code 6)
// Grade D Alpha — stub implementations
// Real API: https://api.cloudflare.com/client/v4/{endpoint}
// Auth: Authorization: Bearer {token}
// ═══════════════════════════════════════════════════════════════════════

/// Grade D Alpha stub for Cloudflare API requests.
/// Real implementation would call https://api.cloudflare.com/client/v4/{endpoint}
/// with Authorization: Bearer {token} header.
fn cloudflareRequest(token: []const u8, endpoint: []const u8, method: []const u8) void {
    // Grade D Alpha stub — logs intent, does not make real HTTP calls.
    // In production this would:
    //   1. Build URL: https://api.cloudflare.com/client/v4/{endpoint}
    //   2. Set header: Authorization: Bearer {token}
    //   3. Execute {method} request
    //   4. Parse JSON response
    _ = token;
    _ = endpoint;
    _ = method;
}

/// Validate that a session slot is active, authenticated/operating, and belongs to cloudflare.
/// Returns the validated index or null if the slot is invalid or wrong provider.
fn validateCloudflareSlot(slot_idx: c_int) ?usize {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return null;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return null;
    if (sessions[idx].provider != .cloudflare) return null;
    if (sessions[idx].state != .authenticated and sessions[idx].state != .operating) return null;
    return idx;
}

/// Write a structured JSON stub response into the session result buffer.
fn writeCloudflareResult(idx: usize, endpoint: []const u8, method: []const u8) void {
    const prefix = "{\"provider\":\"cloudflare\",\"endpoint\":\"";
    const mid1 = "\",\"method\":\"";
    const mid2 = "\",\"status\":\"stub\",\"note\":\"Grade D Alpha\"}";

    var pos: usize = 0;
    const parts = [_][]const u8{ prefix, endpoint, mid1, method, mid2 };
    for (parts) |part| {
        if (pos + part.len > RESULT_BUF_SIZE) break;
        @memcpy(sessions[idx].result_buf[pos .. pos + part.len], part);
        pos += part.len;
    }
    sessions[idx].result_len = pos;
}

/// Set credentials on a Cloudflare session slot.
pub export fn cloud_cf_set_credentials(slot_idx: c_int, token_ptr: [*]const u8, token_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    sessions[idx].cred_kind = .bearer_token;
    sessions[idx].cred_hash = std.hash.Fnv1a_64.hash(token_ptr[0..token_len]);
    return 0;
}

/// List Cloudflare Workers scripts.
pub export fn cloud_cf_list_workers(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    cloudflareRequest(&.{}, "workers/scripts", "GET");
    writeCloudflareResult(idx, "workers/scripts", "GET");
    return 0;
}

/// Get a specific Cloudflare Worker by name.
pub export fn cloud_cf_get_worker(slot_idx: c_int, name_ptr: [*]const u8, name_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    _ = name_ptr[0..name_len];
    cloudflareRequest(&.{}, "workers/scripts/{name}", "GET");
    writeCloudflareResult(idx, "workers/scripts/{name}", "GET");
    return 0;
}

/// List Cloudflare D1 databases.
pub export fn cloud_cf_list_d1(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    cloudflareRequest(&.{}, "d1/database", "GET");
    writeCloudflareResult(idx, "d1/database", "GET");
    return 0;
}

/// Query a Cloudflare D1 database. json_ptr/json_len contain the SQL query JSON.
pub export fn cloud_cf_query_d1(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    cloudflareRequest(&.{}, "d1/database/{id}/query", "POST");
    writeCloudflareResult(idx, "d1/database/{id}/query", "POST");
    return 0;
}

/// List Cloudflare KV namespaces.
pub export fn cloud_cf_list_kv(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    cloudflareRequest(&.{}, "storage/kv/namespaces", "GET");
    writeCloudflareResult(idx, "storage/kv/namespaces", "GET");
    return 0;
}

/// Get a value from a Cloudflare KV namespace. json_ptr/json_len contain namespace + key JSON.
pub export fn cloud_cf_kv_get(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    cloudflareRequest(&.{}, "storage/kv/namespaces/{ns}/values/{key}", "GET");
    writeCloudflareResult(idx, "storage/kv/namespaces/{ns}/values/{key}", "GET");
    return 0;
}

/// Put a value into a Cloudflare KV namespace. json_ptr/json_len contain namespace + key + value JSON.
pub export fn cloud_cf_kv_put(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    cloudflareRequest(&.{}, "storage/kv/namespaces/{ns}/values/{key}", "PUT");
    writeCloudflareResult(idx, "storage/kv/namespaces/{ns}/values/{key}", "PUT");
    return 0;
}

/// List Cloudflare R2 buckets.
pub export fn cloud_cf_list_r2(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    cloudflareRequest(&.{}, "r2/buckets", "GET");
    writeCloudflareResult(idx, "r2/buckets", "GET");
    return 0;
}

/// List Cloudflare DNS zones.
pub export fn cloud_cf_list_dns_zones(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    cloudflareRequest(&.{}, "zones", "GET");
    writeCloudflareResult(idx, "zones", "GET");
    return 0;
}

/// List DNS records for a specific Cloudflare zone.
pub export fn cloud_cf_list_dns_records(slot_idx: c_int, zone_ptr: [*]const u8, zone_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    _ = zone_ptr[0..zone_len];
    cloudflareRequest(&.{}, "zones/{zone}/dns_records", "GET");
    writeCloudflareResult(idx, "zones/{zone}/dns_records", "GET");
    return 0;
}

/// Add a DNS record to a Cloudflare zone. json_ptr/json_len contain record JSON.
pub export fn cloud_cf_add_dns_record(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateCloudflareSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    cloudflareRequest(&.{}, "zones/{zone}/dns_records", "POST");
    writeCloudflareResult(idx, "zones/{zone}/dns_records", "POST");
    return 0;
}

/// Read the result buffer for a Cloudflare session slot. Returns length or -1 on error.
pub export fn cloud_cf_read_result(slot_idx: c_int, out_ptr: [*]u8, out_cap: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    const len = @min(sessions[idx].result_len, out_cap);
    @memcpy(out_ptr[0..len], sessions[idx].result_buf[0..len]);
    return @intCast(len);
}

// ═══════════════════════════════════════════════════════════════════════
// Cloudflare Provider Tests
// ═══════════════════════════════════════════════════════════════════════

test "cloudflare auth and list workers" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.cloudflare));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), cloud_state(slot));

    // Set credential
    const token = "cf_test_token_abc123";
    try std.testing.expectEqual(@as(c_int, 0), cloud_cf_set_credentials(slot, token.ptr, token.len));

    // List workers should succeed
    try std.testing.expectEqual(@as(c_int, 0), cloud_cf_list_workers(slot));

    // Verify result buffer contains expected JSON
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    const rlen = cloud_cf_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(rlen > 0);
    const result = buf[0..@intCast(rlen)];
    try std.testing.expect(std.mem.indexOf(u8, result, "\"provider\":\"cloudflare\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"endpoint\":\"workers/scripts\"") != null);

    _ = cloud_logout(slot);
}

test "cloudflare d1 kv and r2 operations" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.cloudflare));
    try std.testing.expect(slot >= 0);
    const token = "cf_test_token_d1kv";
    _ = cloud_cf_set_credentials(slot, token.ptr, token.len);

    // D1 list
    try std.testing.expectEqual(@as(c_int, 0), cloud_cf_list_d1(slot));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    var rlen = cloud_cf_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"endpoint\":\"d1/database\"") != null);

    // KV list
    try std.testing.expectEqual(@as(c_int, 0), cloud_cf_list_kv(slot));
    rlen = cloud_cf_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"endpoint\":\"storage/kv/namespaces\"") != null);

    // R2 list
    try std.testing.expectEqual(@as(c_int, 0), cloud_cf_list_r2(slot));
    rlen = cloud_cf_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"endpoint\":\"r2/buckets\"") != null);

    _ = cloud_logout(slot);
}

test "cloudflare dns operations" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.cloudflare));
    try std.testing.expect(slot >= 0);
    const token = "cf_test_token_dns";
    _ = cloud_cf_set_credentials(slot, token.ptr, token.len);

    // List DNS zones
    try std.testing.expectEqual(@as(c_int, 0), cloud_cf_list_dns_zones(slot));

    // List DNS records for a zone
    const zone_id = "zone123abc";
    try std.testing.expectEqual(@as(c_int, 0), cloud_cf_list_dns_records(slot, zone_id.ptr, zone_id.len));

    // Add DNS record
    const record_json = "{\"type\":\"A\",\"name\":\"test.example.com\",\"content\":\"192.0.2.1\"}";
    try std.testing.expectEqual(@as(c_int, 0), cloud_cf_add_dns_record(slot, record_json.ptr, record_json.len));

    _ = cloud_logout(slot);
}

test "cloudflare wrong-provider rejection" {
    cloud_reset();
    // Authenticate as AWS, not Cloudflare
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.aws));
    try std.testing.expect(slot >= 0);

    // All Cloudflare operations should reject with -1 (wrong provider)
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_list_workers(slot));
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_list_d1(slot));
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_list_kv(slot));
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_list_r2(slot));
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_list_dns_zones(slot));

    const json_data = "{}";
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_kv_get(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_kv_put(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_query_d1(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_add_dns_record(slot, json_data.ptr, json_data.len));

    const name = "test";
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_get_worker(slot, name.ptr, name.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_list_dns_records(slot, name.ptr, name.len));

    const cf_token = "cf_test";
    try std.testing.expectEqual(@as(c_int, -1), cloud_cf_set_credentials(slot, cf_token.ptr, cf_token.len));

    _ = cloud_logout(slot);
}

// ═══════════════════════════════════════════════════════════════════════
// Verpex Provider (provider code 5)
// Grade D Alpha — stub implementations
// Real API: cPanel UAPI at https://{hostname}:2083/execute/{Module}/{function}
// Auth: Authorization: cpanel {username}:{api_token}
// ═══════════════════════════════════════════════════════════════════════

const CRED_BUF_SIZE: usize = 256;

/// Per-slot Verpex credential storage (hostname + username + api_token).
/// Stored separately because SessionSlot only has a single cred_hash field,
/// and Verpex cPanel auth requires three distinct credential components.
var verpex_hostnames: [MAX_SESSIONS][CRED_BUF_SIZE]u8 = [_][CRED_BUF_SIZE]u8{[_]u8{0} ** CRED_BUF_SIZE} ** MAX_SESSIONS;
var verpex_hostname_lens: [MAX_SESSIONS]usize = [_]usize{0} ** MAX_SESSIONS;
var verpex_usernames: [MAX_SESSIONS][CRED_BUF_SIZE]u8 = [_][CRED_BUF_SIZE]u8{[_]u8{0} ** CRED_BUF_SIZE} ** MAX_SESSIONS;
var verpex_username_lens: [MAX_SESSIONS]usize = [_]usize{0} ** MAX_SESSIONS;
var verpex_tokens: [MAX_SESSIONS][CRED_BUF_SIZE]u8 = [_][CRED_BUF_SIZE]u8{[_]u8{0} ** CRED_BUF_SIZE} ** MAX_SESSIONS;
var verpex_token_lens: [MAX_SESSIONS]usize = [_]usize{0} ** MAX_SESSIONS;

/// Issue a Verpex cPanel UAPI request (Grade D Alpha stub).
/// Real implementation would hit https://{hostname}:2083/execute/{module}/{function}
/// with header: Authorization: cpanel {username}:{api_token}
fn verpexRequest(hostname: []const u8, username: []const u8, token: []const u8, module: []const u8, function: []const u8) void {
    // Grade D Alpha stub — log intent, no network I/O
    _ = hostname;
    _ = username;
    _ = token;
    _ = module;
    _ = function;
}

/// Write a JSON stub response into a session's result buffer for Verpex operations.
fn writeVerpexResult(slot: *SessionSlot, module: []const u8, function: []const u8) void {
    const prefix = "{\"provider\":\"verpex\",\"cpanel_module\":\"";
    const mid1 = "\",\"cpanel_function\":\"";
    const mid2 = "\",\"status\":\"stub\",\"note\":\"Grade D Alpha\"}";

    var pos: usize = 0;
    const parts = [_][]const u8{ prefix, module, mid1, function, mid2 };
    for (parts) |part| {
        if (pos + part.len > RESULT_BUF_SIZE) break;
        @memcpy(slot.result_buf[pos .. pos + part.len], part);
        pos += part.len;
    }
    slot.result_len = pos;
}

/// Validate that a slot is active, authenticated/operating, and bound to the Verpex provider.
fn validateVerpexSlot(slot_idx: c_int) ?usize {
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return null;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return null;
    if (sessions[idx].provider != .verpex) return null;
    if (sessions[idx].state != .authenticated and sessions[idx].state != .operating) return null;
    return idx;
}

/// Set credentials on a Verpex session slot (hostname + username + api_token).
/// Verpex uses cPanel UAPI auth which requires all three components.
pub export fn cloud_verpex_set_credentials(
    slot_idx: c_int,
    host_ptr: [*]const u8,
    host_len: usize,
    user_ptr: [*]const u8,
    user_len: usize,
    token_ptr: [*]const u8,
    token_len: usize,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    if (host_len > CRED_BUF_SIZE or user_len > CRED_BUF_SIZE or token_len > CRED_BUF_SIZE) return -2;

    @memcpy(verpex_hostnames[idx][0..host_len], host_ptr[0..host_len]);
    verpex_hostname_lens[idx] = host_len;
    @memcpy(verpex_usernames[idx][0..user_len], user_ptr[0..user_len]);
    verpex_username_lens[idx] = user_len;
    @memcpy(verpex_tokens[idx][0..token_len], token_ptr[0..token_len]);
    verpex_token_lens[idx] = token_len;

    sessions[idx].cred_kind = .api_key;
    sessions[idx].cred_hash = std.hash.Fnv1a_64.hash(token_ptr[0..token_len]);
    return 0;
}

/// List all domains on the Verpex hosting account (cPanel DomainInfo::list_domains).
pub export fn cloud_verpex_list_domains(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "DomainInfo",
        "list_domains",
    );
    writeVerpexResult(&sessions[idx], "DomainInfo", "list_domains");
    return 0;
}

/// List DNS zone records for a domain (cPanel DNS::parse_zone).
pub export fn cloud_verpex_list_dns(slot_idx: c_int, domain_ptr: [*]const u8, domain_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    _ = domain_ptr[0..domain_len];
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "DNS",
        "parse_zone",
    );
    writeVerpexResult(&sessions[idx], "DNS", "parse_zone");
    return 0;
}

/// Add a DNS record to a domain (cPanel DNS::mass_edit_zone). json_ptr/json_len contain record JSON.
pub export fn cloud_verpex_add_dns(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "DNS",
        "mass_edit_zone",
    );
    writeVerpexResult(&sessions[idx], "DNS", "mass_edit_zone");
    return 0;
}

/// Remove a DNS record from a domain (cPanel DNS::remove_zone_record). json_ptr/json_len contain record JSON.
pub export fn cloud_verpex_remove_dns(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "DNS",
        "remove_zone_record",
    );
    writeVerpexResult(&sessions[idx], "DNS", "remove_zone_record");
    return 0;
}

/// List email accounts (cPanel Email::list_pops).
pub export fn cloud_verpex_list_email(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "Email",
        "list_pops",
    );
    writeVerpexResult(&sessions[idx], "Email", "list_pops");
    return 0;
}

/// Create an email account (cPanel Email::add_pop). json_ptr/json_len contain account JSON.
pub export fn cloud_verpex_create_email(slot_idx: c_int, json_ptr: [*]const u8, json_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    _ = json_ptr[0..json_len];
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "Email",
        "add_pop",
    );
    writeVerpexResult(&sessions[idx], "Email", "add_pop");
    return 0;
}

/// List MySQL databases (cPanel Mysql::list_databases).
pub export fn cloud_verpex_list_databases(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "Mysql",
        "list_databases",
    );
    writeVerpexResult(&sessions[idx], "Mysql", "list_databases");
    return 0;
}

/// Create a MySQL database (cPanel Mysql::create_database).
pub export fn cloud_verpex_create_database(slot_idx: c_int, name_ptr: [*]const u8, name_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    _ = name_ptr[0..name_len];
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "Mysql",
        "create_database",
    );
    writeVerpexResult(&sessions[idx], "Mysql", "create_database");
    return 0;
}

/// Get SSL/TLS certificate status for a domain (cPanel SSL::installed_hosts).
pub export fn cloud_verpex_ssl_status(slot_idx: c_int, domain_ptr: [*]const u8, domain_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    _ = domain_ptr[0..domain_len];
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "SSL",
        "installed_hosts",
    );
    writeVerpexResult(&sessions[idx], "SSL", "installed_hosts");
    return 0;
}

/// List cron jobs (cPanel Cron::list_cron).
pub export fn cloud_verpex_list_cron(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "Cron",
        "list_cron",
    );
    writeVerpexResult(&sessions[idx], "Cron", "list_cron");
    return 0;
}

/// Get hosting metrics and resource usage (cPanel ResourceUsage::get_usages).
pub export fn cloud_verpex_metrics(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const idx = validateVerpexSlot(slot_idx) orelse return -1;
    verpexRequest(
        verpex_hostnames[idx][0..verpex_hostname_lens[idx]],
        verpex_usernames[idx][0..verpex_username_lens[idx]],
        verpex_tokens[idx][0..verpex_token_lens[idx]],
        "ResourceUsage",
        "get_usages",
    );
    writeVerpexResult(&sessions[idx], "ResourceUsage", "get_usages");
    return 0;
}

/// Read the result buffer for a Verpex session slot. Returns length or -1 on error.
pub export fn cloud_verpex_read_result(slot_idx: c_int, out_ptr: [*]u8, out_cap: usize) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (slot_idx < 0 or slot_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(slot_idx);
    if (!sessions[idx].active) return -1;
    const len = @min(sessions[idx].result_len, out_cap);
    @memcpy(out_ptr[0..len], sessions[idx].result_buf[0..len]);
    return @intCast(len);
}

// ═══════════════════════════════════════════════════════════════════════
// Verpex Provider Tests
// ═══════════════════════════════════════════════════════════════════════

test "verpex auth and credential storage" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.verpex));
    try std.testing.expect(slot >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(SessionState.authenticated)), cloud_state(slot));

    // Set credentials (hostname + username + api_token)
    const host = "server42.verpex.com";
    const user = "testuser";
    const token = "ABCDEF0123456789ABCDEF0123456789";
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_set_credentials(
        slot,
        host.ptr,
        host.len,
        user.ptr,
        user.len,
        token.ptr,
        token.len,
    ));

    // Verify credential storage
    const idx: usize = @intCast(slot);
    try std.testing.expectEqual(@as(usize, host.len), verpex_hostname_lens[idx]);
    try std.testing.expectEqualSlices(u8, host, verpex_hostnames[idx][0..verpex_hostname_lens[idx]]);
    try std.testing.expectEqual(@as(usize, user.len), verpex_username_lens[idx]);
    try std.testing.expectEqualSlices(u8, user, verpex_usernames[idx][0..verpex_username_lens[idx]]);

    try std.testing.expectEqual(@as(c_int, 0), cloud_logout(slot));
}

test "verpex domain and dns operations" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.verpex));
    try std.testing.expect(slot >= 0);
    const host = "server42.verpex.com";
    const user = "testuser";
    const token = "ABCDEF0123456789";
    _ = cloud_verpex_set_credentials(slot, host.ptr, host.len, user.ptr, user.len, token.ptr, token.len);

    // list_domains
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_list_domains(slot));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    var rlen = cloud_verpex_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(rlen > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"provider\":\"verpex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"cpanel_module\":\"DomainInfo\"") != null);

    // list_dns
    const domain = "example.com";
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_list_dns(slot, domain.ptr, domain.len));
    rlen = cloud_verpex_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"cpanel_module\":\"DNS\"") != null);

    // add_dns
    const add_json = "{\"zone\":\"example.com\",\"type\":\"A\",\"name\":\"test\",\"address\":\"192.0.2.1\"}";
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_add_dns(slot, add_json.ptr, add_json.len));

    // remove_dns
    const rm_json = "{\"zone\":\"example.com\",\"line\":42}";
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_remove_dns(slot, rm_json.ptr, rm_json.len));

    _ = cloud_logout(slot);
}

test "verpex email and database operations" {
    cloud_reset();
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.verpex));
    try std.testing.expect(slot >= 0);
    const host = "server42.verpex.com";
    const user = "testuser";
    const token = "ABCDEF0123456789";
    _ = cloud_verpex_set_credentials(slot, host.ptr, host.len, user.ptr, user.len, token.ptr, token.len);

    // list_email
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_list_email(slot));
    var buf: [RESULT_BUF_SIZE]u8 = undefined;
    var rlen = cloud_verpex_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"cpanel_module\":\"Email\"") != null);

    // create_email
    const email_json = "{\"email\":\"info@example.com\",\"password\":\"s3cure!\",\"quota\":1024}";
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_create_email(slot, email_json.ptr, email_json.len));

    // list_databases
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_list_databases(slot));
    rlen = cloud_verpex_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"cpanel_module\":\"Mysql\"") != null);

    // create_database
    const db_name = "testuser_mydb";
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_create_database(slot, db_name.ptr, db_name.len));

    // ssl_status
    const domain = "example.com";
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_ssl_status(slot, domain.ptr, domain.len));
    rlen = cloud_verpex_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"cpanel_module\":\"SSL\"") != null);

    // list_cron
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_list_cron(slot));

    // metrics
    try std.testing.expectEqual(@as(c_int, 0), cloud_verpex_metrics(slot));
    rlen = cloud_verpex_read_result(slot, &buf, RESULT_BUF_SIZE);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..@intCast(rlen)], "\"cpanel_module\":\"ResourceUsage\"") != null);

    _ = cloud_logout(slot);
}

test "verpex wrong-provider rejection" {
    cloud_reset();
    // Authenticate as AWS, not Verpex — all Verpex operations should fail
    const slot = cloud_authenticate(@intFromEnum(CloudProvider.aws));
    try std.testing.expect(slot >= 0);

    const host = "server42.verpex.com";
    const user = "testuser";
    const token = "ABCDEF0123456789";
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_set_credentials(
        slot,
        host.ptr,
        host.len,
        user.ptr,
        user.len,
        token.ptr,
        token.len,
    ));

    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_list_domains(slot));
    const domain = "example.com";
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_list_dns(slot, domain.ptr, domain.len));

    const json_data = "{}";
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_add_dns(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_remove_dns(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_list_email(slot));
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_create_email(slot, json_data.ptr, json_data.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_list_databases(slot));
    const name = "testdb";
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_create_database(slot, name.ptr, name.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_ssl_status(slot, domain.ptr, domain.len));
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_list_cron(slot));
    try std.testing.expectEqual(@as(c_int, -1), cloud_verpex_metrics(slot));

    _ = cloud_logout(slot);
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "cloud_authenticate",
        "cloud_logout",
        "cloud_state",
        "cloud_execute",
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
    const rc = boj_cartridge_invoke("cloud_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
