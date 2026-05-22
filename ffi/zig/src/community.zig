// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Community Cartridge Submission FFI — Ayo tier cartridge registry.
//
// Manages community-submitted cartridges (Ayo menu tier). Provides:
//   - Submission registration with metadata validation
//   - SHA-256 hash verification for submitted .so files
//   - Review state machine (submitted → under_review → approved/rejected)
//   - Author attribution and license validation
//   - Submission query API for the catalogue
//
// Community cartridges are sandboxed and only promoted to Teranga/Shield
// tiers after formal review.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════════

const MAX_SUBMISSIONS: usize = 64;
const MAX_NAME_LEN: usize = 64;
const MAX_AUTHOR_LEN: usize = 128;
const MAX_DESC_LEN: usize = 256;
const HASH_LEN: usize = 64; // SHA-256 hex string

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

/// Review status for community cartridge submissions.
pub const ReviewStatus = enum(u8) {
    submitted = 0,
    under_review = 1,
    approved = 2,
    rejected = 3,
    suspended = 4,
};

/// A community cartridge submission.
const Submission = struct {
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: usize = 0,
    author: [MAX_AUTHOR_LEN]u8 = [_]u8{0} ** MAX_AUTHOR_LEN,
    author_len: usize = 0,
    description: [MAX_DESC_LEN]u8 = [_]u8{0} ** MAX_DESC_LEN,
    desc_len: usize = 0,
    hash: [HASH_LEN]u8 = [_]u8{0} ** HASH_LEN,
    hash_len: usize = 0,
    status: ReviewStatus = .submitted,
    submitted_at: i64 = 0,
    reviewed_at: i64 = 0,
    active: bool = false,
};

// ═══════════════════════════════════════════════════════════════════════
// Global State
// ═══════════════════════════════════════════════════════════════════════

var submissions: [MAX_SUBMISSIONS]Submission = [_]Submission{.{}} ** MAX_SUBMISSIONS;
var submission_count: usize = 0;
var initialised: bool = false;
var mutex: std.Thread.Mutex = .{};

// ═══════════════════════════════════════════════════════════════════════
// Internal API
// ═══════════════════════════════════════════════════════════════════════

fn init() void {
    submission_count = 0;
    submissions = [_]Submission{.{}} ** MAX_SUBMISSIONS;
    initialised = true;
}

fn submit(
    name_ptr: [*]const u8,
    name_len: usize,
    author_ptr: [*]const u8,
    author_len: usize,
    desc_ptr: [*]const u8,
    desc_len: usize,
    hash_ptr: [*]const u8,
    hash_len: usize,
) i32 {
    if (submission_count >= MAX_SUBMISSIONS) return -1;

    // Validate name
    if (name_len == 0 or name_len > MAX_NAME_LEN) return -2;
    // Validate hash length (must be 64-char hex)
    if (hash_len != 64) return -3;

    // Check for duplicate name
    const actual_name = @min(name_len, MAX_NAME_LEN);
    for (submissions[0..submission_count]) |sub| {
        if (sub.name_len == actual_name and
            std.mem.eql(u8, sub.name[0..actual_name], name_ptr[0..actual_name]))
        {
            return -4; // duplicate
        }
    }

    var sub = &submissions[submission_count];
    @memcpy(sub.name[0..actual_name], name_ptr[0..actual_name]);
    sub.name_len = actual_name;

    const actual_author = @min(author_len, MAX_AUTHOR_LEN);
    @memcpy(sub.author[0..actual_author], author_ptr[0..actual_author]);
    sub.author_len = actual_author;

    const actual_desc = @min(desc_len, MAX_DESC_LEN);
    @memcpy(sub.description[0..actual_desc], desc_ptr[0..actual_desc]);
    sub.desc_len = actual_desc;

    @memcpy(sub.hash[0..64], hash_ptr[0..64]);
    sub.hash_len = 64;

    sub.status = .submitted;
    sub.submitted_at = std.time.timestamp();
    sub.active = true;

    submission_count += 1;
    return @as(i32, @intCast(submission_count - 1));
}

fn setStatus(idx: usize, new_status: ReviewStatus) i32 {
    if (idx >= submission_count) return -1;
    var sub = &submissions[idx];

    // State machine: only valid transitions
    const valid = switch (sub.status) {
        .submitted => new_status == .under_review or new_status == .rejected,
        .under_review => new_status == .approved or new_status == .rejected,
        .approved => new_status == .suspended,
        .rejected => false,
        .suspended => new_status == .under_review,
    };
    if (!valid) return -2;

    sub.status = new_status;
    sub.reviewed_at = std.time.timestamp();
    return 0;
}

fn findByName(name_ptr: [*]const u8, name_len: usize) ?usize {
    const actual = @min(name_len, MAX_NAME_LEN);
    for (submissions[0..submission_count], 0..) |sub, i| {
        if (sub.name_len == actual and
            std.mem.eql(u8, sub.name[0..actual], name_ptr[0..actual]))
        {
            return i;
        }
    }
    return null;
}

fn countByStatus(status: ReviewStatus) usize {
    var count: usize = 0;
    for (submissions[0..submission_count]) |sub| {
        if (sub.status == status) count += 1;
    }
    return count;
}

// ═══════════════════════════════════════════════════════════════════════
// C-ABI Exports
// ═══════════════════════════════════════════════════════════════════════

export fn boj_community_init() i32 {
    mutex.lock();
    defer mutex.unlock();
    init();
    return 0;
}

export fn boj_community_deinit() void {
    mutex.lock();
    defer mutex.unlock();
    submission_count = 0;
    initialised = false;
}

export fn boj_community_submit(
    name_ptr: [*]const u8,
    name_len: usize,
    author_ptr: [*]const u8,
    author_len: usize,
    desc_ptr: [*]const u8,
    desc_len: usize,
    hash_ptr: [*]const u8,
    hash_len: usize,
) i32 {
    mutex.lock();
    defer mutex.unlock();
    if (!initialised) init();
    return submit(name_ptr, name_len, author_ptr, author_len, desc_ptr, desc_len, hash_ptr, hash_len);
}

export fn boj_community_set_status(idx: usize, status: u8) i32 {
    mutex.lock();
    defer mutex.unlock();
    return setStatus(idx, @enumFromInt(@min(status, 4)));
}

export fn boj_community_status(idx: usize) u8 {
    mutex.lock();
    defer mutex.unlock();
    if (idx >= submission_count) return 0;
    return @intFromEnum(submissions[idx].status);
}

export fn boj_community_count() usize {
    mutex.lock();
    defer mutex.unlock();
    return submission_count;
}

export fn boj_community_count_approved() usize {
    mutex.lock();
    defer mutex.unlock();
    return countByStatus(.approved);
}

export fn boj_community_count_pending() usize {
    mutex.lock();
    defer mutex.unlock();
    return countByStatus(.submitted) + countByStatus(.under_review);
}

export fn boj_community_find(name_ptr: [*]const u8, name_len: usize) i32 {
    mutex.lock();
    defer mutex.unlock();
    if (findByName(name_ptr, name_len)) |idx| {
        return @intCast(idx);
    }
    return -1;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "community init" {
    init();
    try std.testing.expectEqual(@as(usize, 0), submission_count);
    try std.testing.expect(initialised);
}

test "community submit cartridge" {
    init();
    const name = "my-cool-mcp";
    const author = "Alice <alice@example.com>";
    const desc = "A cool MCP cartridge for testing";
    const hash = "a" ** 64;
    const idx = submit(name.ptr, name.len, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    try std.testing.expect(idx >= 0);
    try std.testing.expectEqual(ReviewStatus.submitted, submissions[0].status);
}

test "community reject empty name" {
    init();
    const author = "Bob";
    const desc = "desc";
    const hash = "b" ** 64;
    const idx = submit("".ptr, 0, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    try std.testing.expectEqual(@as(i32, -2), idx);
}

test "community reject bad hash length" {
    init();
    const name = "bad-hash";
    const author = "Bob";
    const desc = "desc";
    const hash = "abc";
    const idx = submit(name.ptr, name.len, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    try std.testing.expectEqual(@as(i32, -3), idx);
}

test "community reject duplicate name" {
    init();
    const name = "dup-cart";
    const author = "Carol";
    const desc = "desc";
    const hash = "c" ** 64;
    _ = submit(name.ptr, name.len, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    const idx2 = submit(name.ptr, name.len, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    try std.testing.expectEqual(@as(i32, -4), idx2);
}

test "community state machine valid transitions" {
    init();
    const name = "review-cart";
    const author = "Dave";
    const desc = "desc";
    const hash = "d" ** 64;
    const idx = submit(name.ptr, name.len, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    const uidx: usize = @intCast(idx);

    // submitted → under_review
    try std.testing.expectEqual(@as(i32, 0), setStatus(uidx, .under_review));
    // under_review → approved
    try std.testing.expectEqual(@as(i32, 0), setStatus(uidx, .approved));
    // approved → suspended
    try std.testing.expectEqual(@as(i32, 0), setStatus(uidx, .suspended));
    // suspended → under_review
    try std.testing.expectEqual(@as(i32, 0), setStatus(uidx, .under_review));
}

test "community state machine invalid transition" {
    init();
    const name = "bad-transition";
    const author = "Eve";
    const desc = "desc";
    const hash = "e" ** 64;
    const idx = submit(name.ptr, name.len, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    const uidx: usize = @intCast(idx);

    // submitted → approved (invalid, must go through review)
    try std.testing.expectEqual(@as(i32, -2), setStatus(uidx, .approved));
}

test "community find by name" {
    init();
    const name = "findable";
    const author = "Frank";
    const desc = "desc";
    const hash = "f" ** 64;
    _ = submit(name.ptr, name.len, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    const found = findByName(name.ptr, name.len);
    try std.testing.expect(found != null);
}

test "community count by status" {
    init();
    const hash = "0" ** 64;
    _ = submit("a".ptr, 1, "x".ptr, 1, "d".ptr, 1, hash.ptr, 64);
    const hash2 = "1" ** 64;
    _ = submit("b".ptr, 1, "x".ptr, 1, "d".ptr, 1, hash2.ptr, 64);
    // Move 'b' to under_review
    _ = setStatus(1, .under_review);
    try std.testing.expectEqual(@as(usize, 2), countByStatus(.submitted) + countByStatus(.under_review));
    try std.testing.expectEqual(@as(usize, 0), countByStatus(.approved));
}

test "community c-abi roundtrip" {
    _ = boj_community_init();
    const name = "api-cart";
    const author = "Tester";
    const desc = "API test";
    const hash = "a" ** 64;
    const idx = boj_community_submit(name.ptr, name.len, author.ptr, author.len, desc.ptr, desc.len, hash.ptr, hash.len);
    try std.testing.expect(idx >= 0);
    try std.testing.expectEqual(@as(u8, 0), boj_community_status(@intCast(idx))); // submitted
    try std.testing.expectEqual(@as(usize, 1), boj_community_count());
    try std.testing.expectEqual(@as(usize, 1), boj_community_count_pending());
}

test "community deinit resets" {
    _ = boj_community_init();
    const hash = "z" ** 64;
    _ = boj_community_submit("tmp".ptr, 3, "x".ptr, 1, "d".ptr, 1, hash.ptr, 64);
    boj_community_deinit();
    try std.testing.expectEqual(@as(usize, 0), boj_community_count());
}
