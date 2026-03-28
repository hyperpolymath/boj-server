// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// CivicConnect FFI — C-compatible exports for civic platform communications.

const std = @import("std");

/// List active channel count.
export fn civic_connect_list_channels_count() callconv(.C) u32 {
    return 0; // Stub
}

/// Send a message to a channel. Returns 0 on success, -1 on error.
export fn civic_connect_send_message(channel_id: u32, body: [*c]const u8) callconv(.C) i32 {
    if (channel_id == 0 or body == null) return -1;
    return 0; // Stub
}

/// Get poll results. Returns total vote count, or 0 if poll not found.
export fn civic_connect_get_poll(poll_id: u32) callconv(.C) u32 {
    if (poll_id == 0) return 0;
    return 0; // Stub
}

// ── Tests ──

test "send rejects null body" {
    try std.testing.expectEqual(@as(i32, -1), civic_connect_send_message(1, null));
}

test "send rejects zero channel" {
    try std.testing.expectEqual(@as(i32, -1), civic_connect_send_message(0, "hello"));
}

test "poll returns zero for invalid id" {
    try std.testing.expectEqual(@as(u32, 0), civic_connect_get_poll(0));
}
