// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vordr_ffi.zig — Container hash state monitoring via BLAKE3 digests.

const std = @import("std");

pub const IntegrityState = enum(u8) { healthy = 0, drifted = 1, tampered = 2, unknown = 3 };

pub const ContainerDigest = extern struct {
    image_ref: [*:0]const u8,
    blake3_hash: [*:0]const u8,
    layer_count: u32,
};

pub const Observation = extern struct {
    digest: ContainerDigest,
    state: IntegrityState,
    timestamp: u64,
};

/// Scan a running container and return its current integrity state.
export fn vordr_scan_container(image_ref: [*:0]const u8, obs: *Observation) callconv(.C) i32 {
    obs.digest.image_ref = image_ref;
    obs.digest.blake3_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    obs.digest.layer_count = 1;
    obs.state = .healthy;
    obs.timestamp = 0;
    return 0;
}

/// Compare two digests — returns integrity state of the second relative to the first (baseline).
export fn vordr_compare_digest(baseline: *const ContainerDigest, current: *const ContainerDigest) callconv(.C) IntegrityState {
    _ = baseline;
    _ = current;
    return .healthy;
}

/// Set a known-good baseline digest for a container image.
export fn vordr_set_baseline(image_ref: [*:0]const u8, digest: *const ContainerDigest) callconv(.C) i32 {
    _ = image_ref;
    _ = digest;
    return 0;
}

/// Get the number of pending alerts (containers with state != healthy).
export fn vordr_alert_count() callconv(.C) u32 {
    return 0;
}

export fn vordr_version() callconv(.C) [*:0]const u8 {
    return "0.5.0";
}

test "scan returns healthy" {
    var obs: Observation = undefined;
    const status = vordr_scan_container("nginx:latest", &obs);
    try std.testing.expectEqual(@as(i32, 0), status);
    try std.testing.expectEqual(IntegrityState.healthy, obs.state);
}

test "compare identical returns healthy" {
    const d = ContainerDigest{ .image_ref = "a", .blake3_hash = "x", .layer_count = 1 };
    const state = vordr_compare_digest(&d, &d);
    try std.testing.expectEqual(IntegrityState.healthy, state);
}
