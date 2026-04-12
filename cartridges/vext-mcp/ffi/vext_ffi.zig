// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Vext FFI — C-compatible exports for verifiable communications.

const std = @import("std");

/// Verify status codes: 0=verified, 1=unverified, 2=tampered, 3=expired.
pub const VerifyStatus = enum(u8) { verified = 0, unverified = 1, tampered = 2, expired = 3 };

/// Verify a message. Returns status code.
export fn vext_verify_message(msg: [*c]const u8, sig: [*c]const u8) u8 {
    if (msg == null or sig == null) return @intFromEnum(VerifyStatus.unverified);
    return @intFromEnum(VerifyStatus.verified); // Stub
}

/// Check an attestation by issuer. Returns depth or 0 if not found.
export fn vext_check_attestation(issuer: [*c]const u8) u32 {
    if (issuer == null) return 0;
    return 1; // Stub
}

/// Append an entry to the verification chain. Returns 0 on success.
export fn vext_append_chain(payload: [*c]const u8) i32 {
    if (payload == null) return -1;
    return 0; // Stub
}

// ── Tests ──

test "verify rejects null message" {
    try std.testing.expectEqual(@as(u8, 1), vext_verify_message(null, "sig"));
}

test "verify accepts valid inputs" {
    try std.testing.expectEqual(@as(u8, 0), vext_verify_message("hello", "sig"));
}

test "append rejects null payload" {
    try std.testing.expectEqual(@as(i32, -1), vext_append_chain(null));
}
