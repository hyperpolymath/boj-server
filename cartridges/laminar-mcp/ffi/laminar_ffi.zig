// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Laminar FFI — C-compatible exports for pipeline orchestration.

const std = @import("std");

/// Create a pipeline. Returns pipeline ID or 0 on failure.
export fn laminar_create_pipeline(name: [*c]const u8) u32 {
    if (name == null) return 0;
    return 1; // Stub
}

/// Run the next stage. Returns 0 on success, -1 on error.
export fn laminar_run_stage(pipeline_id: u32, stage_name: [*c]const u8) i32 {
    if (pipeline_id == 0 or stage_name == null) return -1;
    return 0; // Stub
}

/// Get pipeline status: 0=pending, 1=running, 2=succeeded, 3=failed, 4=cancelled.
export fn laminar_get_status(pipeline_id: u32) u8 {
    if (pipeline_id == 0) return 3; // Failed for invalid ID
    return 1; // Stub — running
}

/// Cancel a pipeline. Returns 0 on success.
export fn laminar_cancel_pipeline(pipeline_id: u32) i32 {
    if (pipeline_id == 0) return -1;
    return 0; // Stub
}

// ── Tests ──

test "create rejects null name" {
    try std.testing.expectEqual(@as(u32, 0), laminar_create_pipeline(null));
}

test "run stage rejects invalid pipeline" {
    try std.testing.expectEqual(@as(i32, -1), laminar_run_stage(0, "build"));
}

test "cancel rejects invalid pipeline" {
    try std.testing.expectEqual(@as(i32, -1), laminar_cancel_pipeline(0));
}
