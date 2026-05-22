// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// aws_mcp_ffi.zig — C-ABI FFI implementation for aws-mcp cartridge.
//
// Implements the state machine defined in AwsMcp.SafeCloud (Idris2 ABI).
// State machine: Unauthenticated | Authenticated | RateLimited | Error
// Auth: AWS Signature V4 (access_key_id + secret_access_key + region +
//   optional session_token) via vault-mcp.
// Services: S3, Lambda, DynamoDB, SQS, CloudWatch, IAM, STS with
//   configurable region and endpoint routing.
// Thread-safe via std.Thread.Mutex. Fixed-size session pool, no heap allocations.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI SessionState exactly)
// ---------------------------------------------------------------------------

/// Session authentication/lifecycle state.
/// 0 = Unauthenticated, 1 = Authenticated, 2 = RateLimited, 3 = Error.
pub const SessionState = enum(c_int) {
    unauthenticated = 0,
    authenticated = 1,
    rate_limited = 2,
    err = 3,
};

/// AWS service identifiers matching Idris2 AwsService encoding.
/// 0=S3, 1=Lambda, 2=DynamoDB, 3=SQS, 4=CloudWatch, 5=IAM, 6=STS.
pub const AwsService = enum(c_int) {
    s3 = 0,
    lambda = 1,
    dynamodb = 2,
    sqs = 3,
    cloudwatch = 4,
    iam = 5,
    sts = 6,
};

/// AWS action identifiers matching Idris2 AwsAction encoding.
/// Actions 0-4: S3 (ListBuckets, GetObject, PutObject, DeleteObject, PresignedUrl)
/// Actions 5-6: Lambda (ListFunctions, Invoke)
/// Actions 7-10: DynamoDB (Query, Scan, PutItem, GetItem)
/// Actions 11-14: SQS (ListQueues, SendMessage, ReceiveMessage, DeleteMessage)
/// Actions 15-16: CloudWatch (GetMetrics, PutMetricData)
/// Actions 17-18: IAM (ListUsers, ListRoles) — read-only
/// Actions 19-20: STS (GetCallerIdentity, AssumeRole)
pub const AwsAction = enum(c_int) {
    // S3
    s3_list_buckets = 0,
    s3_get_object = 1,
    s3_put_object = 2,
    s3_delete_object = 3,
    s3_presigned_url = 4,
    // Lambda
    lambda_list_functions = 5,
    lambda_invoke = 6,
    // DynamoDB
    dynamo_query = 7,
    dynamo_scan = 8,
    dynamo_put_item = 9,
    dynamo_get_item = 10,
    // SQS
    sqs_list_queues = 11,
    sqs_send_message = 12,
    sqs_receive_message = 13,
    sqs_delete_message = 14,
    // CloudWatch
    cw_get_metrics = 15,
    cw_put_metric_data = 16,
    // IAM (read-only)
    iam_list_users = 17,
    iam_list_roles = 18,
    // STS
    sts_get_caller_identity = 19,
    sts_assume_role = 20,
};

/// Check valid state transitions per the Idris2 ValidTransition proof.
fn isValidTransition(from: SessionState, to: SessionState) bool {
    return switch (from) {
        .unauthenticated => to == .authenticated,
        .authenticated => to == .unauthenticated or to == .rate_limited or to == .err,
        .rate_limited => to == .authenticated,
        .err => to == .unauthenticated,
    };
}

/// Map action integer to its service integer. Returns -1 for invalid action.
fn actionToService(action: c_int) c_int {
    const a = std.meta.intToEnum(AwsAction, action) catch return -1;
    return switch (a) {
        .s3_list_buckets, .s3_get_object, .s3_put_object, .s3_delete_object, .s3_presigned_url => 0,
        .lambda_list_functions, .lambda_invoke => 1,
        .dynamo_query, .dynamo_scan, .dynamo_put_item, .dynamo_get_item => 2,
        .sqs_list_queues, .sqs_send_message, .sqs_receive_message, .sqs_delete_message => 3,
        .cw_get_metrics, .cw_put_metric_data => 4,
        .iam_list_users, .iam_list_roles => 5,
        .sts_get_caller_identity, .sts_assume_role => 6,
    };
}

/// Check if an action is mutating (write operation). Returns 1 for mutating, 0 for read-only.
fn actionIsMutating(action: c_int) c_int {
    const a = std.meta.intToEnum(AwsAction, action) catch return -1;
    return switch (a) {
        .s3_put_object, .s3_delete_object, .lambda_invoke, .dynamo_put_item, .sqs_send_message, .sqs_delete_message, .cw_put_metric_data, .sts_assume_role => 1,
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const REGION_BUF_SIZE: usize = 64;
const KEY_BUF_SIZE: usize = 256;

const SessionSlot = struct {
    active: bool = false,
    state: SessionState = .unauthenticated,
    region_buf: [REGION_BUF_SIZE]u8 = .{0} ** REGION_BUF_SIZE,
    region_len: usize = 0,
    access_key_buf: [KEY_BUF_SIZE]u8 = .{0} ** KEY_BUF_SIZE,
    access_key_len: usize = 0,
    api_call_count: u64 = 0,
    last_action: c_int = -1,
};

var sessions: [MAX_SESSIONS]SessionSlot = .{SessionSlot{}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{};

// ---------------------------------------------------------------------------
// C-ABI exports — state machine
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn aws_mcp_can_transition(from: c_int, to: c_int) c_int {
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}

/// Authenticate a session with region. Returns slot index (>= 0) or error (< 0).
/// Error codes: -1 = no free slots, -2 = region too long.
pub export fn aws_mcp_authenticate(region_ptr: [*]const u8, region_len: c_int) c_int {
    const rlen: usize = std.math.cast(usize, region_len) orelse return -2;
    if (rlen > REGION_BUF_SIZE) return -2;

    mutex.lock();
    defer mutex.unlock();

    for (&sessions, 0..) |*slot, idx| {
        if (!slot.active) {
            slot.active = true;
            slot.state = .authenticated;
            @memcpy(slot.region_buf[0..rlen], region_ptr[0..rlen]);
            slot.region_len = rlen;
            slot.access_key_len = 0;
            slot.api_call_count = 0;
            slot.last_action = -1;
            return @intCast(idx);
        }
    }
    return -1;
}

/// Deauthenticate (close) a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = invalid state transition.
pub export fn aws_mcp_deauthenticate(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .unauthenticated)) return -2;

    sessions[idx] = SessionSlot{};
    return 0;
}

/// Get current state of a session. Returns state int or -1 if invalid.
pub export fn aws_mcp_session_state(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}

/// Signal rate limiting on a session. Returns 0 on success.
pub export fn aws_mcp_throttle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .rate_limited)) return -2;

    sessions[idx].state = .rate_limited;
    return 0;
}

/// Clear rate limiting (resume authenticated). Returns 0 on success.
pub export fn aws_mcp_unthrottle(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .authenticated)) return -2;

    sessions[idx].state = .authenticated;
    return 0;
}

/// Signal an error on a session. Returns 0 on success.
pub export fn aws_mcp_signal_error(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    sessions[idx].state = .err;
    return 0;
}

// ---------------------------------------------------------------------------
// C-ABI exports — service routing and actions
// ---------------------------------------------------------------------------

/// Get the service for an action. Returns service int (0-6) or -1 for invalid.
pub export fn aws_mcp_action_service(action: c_int) c_int {
    return actionToService(action);
}

/// Check if an action is mutating. Returns 1 (mutating), 0 (read-only), -1 (invalid).
pub export fn aws_mcp_action_is_mutating(action: c_int) c_int {
    return actionIsMutating(action);
}

/// Record an API call on a session. Returns 0 on success.
/// Error codes: -1 = invalid slot, -2 = not authenticated, -3 = invalid action.
pub export fn aws_mcp_record_call(slot_idx: c_int, action: c_int) c_int {
    _ = std.meta.intToEnum(AwsAction, action) catch return -3;

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    if (slot.state != .authenticated) return -2;

    sessions[idx].api_call_count += 1;
    sessions[idx].last_action = action;
    return 0;
}

/// Get API call count for a session. Returns count or -1 if invalid.
pub export fn aws_mcp_call_count(slot_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intCast(slot.api_call_count);
}

/// Get total service count. Always returns 7.
pub export fn aws_mcp_service_count() c_int {
    return 7;
}

/// Get total action count. Always returns 21.
pub export fn aws_mcp_action_count() c_int {
    return 21;
}

/// Reset all sessions (test/debug use only).
pub export fn aws_mcp_reset() void {
    mutex.lock();
    defer mutex.unlock();
    sessions = .{SessionSlot{}} ** MAX_SESSIONS;
}

// ---------------------------------------------------------------------------
// ═══════════════════════════════════════════════════════════════════════
// Standard ABI (ADR-0005 four symbols + ADR-0006 invoke)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

const CARTRIDGE_NAME_PTR: [*:0]const u8 = "aws-mcp";
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

    const body: []const u8 =     if (shim.toolIs(tool_name, "aws_authenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "aws_s3_list"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "aws_s3_get"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "aws_s3_put"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "aws_ec2_list"))
        "{\"result\":{\"items\":[],\"count\":0,\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "aws_lambda_invoke"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "aws_session_state"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "aws_deauthenticate"))
        "{\"result\":{\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// Tests
// ---------------------------------------------------------------------------

test "authentication lifecycle" {
    aws_mcp_reset();

    const region = "us-east-1";
    const slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(slot >= 0);

    // Should be authenticated (1)
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_session_state(slot));

    // Record an S3 ListBuckets call
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_record_call(slot, 0));
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_call_count(slot));

    // Deauthenticate
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_deauthenticate(slot));
}

test "rate limiting flow" {
    aws_mcp_reset();

    const region = "eu-west-1";
    const slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(slot >= 0);

    // Throttle
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, 2), aws_mcp_session_state(slot));

    // Cannot invoke while rate limited
    try std.testing.expectEqual(@as(c_int, -2), aws_mcp_record_call(slot, 0));

    // Unthrottle
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_unthrottle(slot));
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_session_state(slot));
}

test "error and recovery" {
    aws_mcp_reset();

    const region = "ap-south-1";
    const slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(slot >= 0);

    // Signal error
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_signal_error(slot));
    try std.testing.expectEqual(@as(c_int, 3), aws_mcp_session_state(slot));

    // Recover to unauthenticated
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_deauthenticate(slot));
}

test "invalid transitions rejected" {
    aws_mcp_reset();

    const region = "us-west-2";
    const slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(slot >= 0);

    // Cannot throttle from rate_limited (must be authenticated)
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_throttle(slot));
    try std.testing.expectEqual(@as(c_int, -2), aws_mcp_throttle(slot));

    // Cannot signal error from rate_limited
    try std.testing.expectEqual(@as(c_int, -2), aws_mcp_signal_error(slot));
}

test "transition validator" {
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(0, 1)); // unauth -> auth
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(1, 0)); // auth -> unauth
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(1, 2)); // auth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(2, 1)); // rate_limited -> auth
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(1, 3)); // auth -> error
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_can_transition(3, 0)); // error -> unauth

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_can_transition(0, 2)); // unauth -> rate_limited
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_can_transition(0, 3)); // unauth -> error
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_can_transition(2, 0)); // rate_limited -> unauth
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_can_transition(3, 1)); // error -> auth
}

test "action service routing — all 7 services" {
    // S3
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_service(0)); // S3ListBuckets
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_service(4)); // S3PresignedUrl
    // Lambda
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_service(5)); // LambdaListFunctions
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_service(6)); // LambdaInvoke
    // DynamoDB
    try std.testing.expectEqual(@as(c_int, 2), aws_mcp_action_service(7)); // DynamoQuery
    try std.testing.expectEqual(@as(c_int, 2), aws_mcp_action_service(10)); // DynamoGetItem
    // SQS
    try std.testing.expectEqual(@as(c_int, 3), aws_mcp_action_service(11)); // SqsListQueues
    try std.testing.expectEqual(@as(c_int, 3), aws_mcp_action_service(14)); // SqsDeleteMessage
    // CloudWatch
    try std.testing.expectEqual(@as(c_int, 4), aws_mcp_action_service(15)); // CwGetMetrics
    try std.testing.expectEqual(@as(c_int, 4), aws_mcp_action_service(16)); // CwPutMetricData
    // IAM
    try std.testing.expectEqual(@as(c_int, 5), aws_mcp_action_service(17)); // IamListUsers
    try std.testing.expectEqual(@as(c_int, 5), aws_mcp_action_service(18)); // IamListRoles
    // STS
    try std.testing.expectEqual(@as(c_int, 6), aws_mcp_action_service(19)); // StsGetCallerIdentity
    try std.testing.expectEqual(@as(c_int, 6), aws_mcp_action_service(20)); // StsAssumeRole
    // Invalid
    try std.testing.expectEqual(@as(c_int, -1), aws_mcp_action_service(99));
}

test "action mutability checks" {
    // Read-only actions
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(0)); // S3ListBuckets
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(1)); // S3GetObject
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(4)); // S3PresignedUrl
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(7)); // DynamoQuery
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(8)); // DynamoScan
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(15)); // CwGetMetrics
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(17)); // IamListUsers
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(18)); // IamListRoles
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_action_is_mutating(19)); // StsGetCallerIdentity

    // Mutating actions
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_is_mutating(2)); // S3PutObject
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_is_mutating(3)); // S3DeleteObject
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_is_mutating(6)); // LambdaInvoke
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_is_mutating(9)); // DynamoPutItem
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_is_mutating(12)); // SqsSendMessage
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_is_mutating(16)); // CwPutMetricData
    try std.testing.expectEqual(@as(c_int, 1), aws_mcp_action_is_mutating(20)); // StsAssumeRole

    // Invalid
    try std.testing.expectEqual(@as(c_int, -1), aws_mcp_action_is_mutating(99));
}

test "slot exhaustion" {
    aws_mcp_reset();

    const region = "us-east-1";
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&slots) |*s| {
        s.* = aws_mcp_authenticate(region.ptr, @intCast(region.len));
        try std.testing.expect(s.* >= 0);
    }

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), aws_mcp_authenticate(region.ptr, @intCast(region.len)));

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), aws_mcp_deauthenticate(slots[0]));
    const new_slot = aws_mcp_authenticate(region.ptr, @intCast(region.len));
    try std.testing.expect(new_slot >= 0);
}

test "counts" {
    try std.testing.expectEqual(@as(c_int, 7), aws_mcp_service_count());
    try std.testing.expectEqual(@as(c_int, 21), aws_mcp_action_count());
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "boj_cartridge_name returns aws-mcp" {
    const n = std.mem.span(boj_cartridge_name());
    try std.testing.expectEqualStrings("aws-mcp", n);
}

test "boj_cartridge_init returns 0" {
    try std.testing.expectEqual(@as(c_int, 0), boj_cartridge_init());
}

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "aws_authenticate",
        "aws_s3_list",
        "aws_s3_get",
        "aws_s3_put",
        "aws_ec2_list",
        "aws_lambda_invoke",
        "aws_session_state",
        "aws_deauthenticate",
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
    const rc = boj_cartridge_invoke("aws_authenticate", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
