// SPDX-License-Identifier: PMPL-1.0-or-later
// Sanctify Cartridge FFI — PHP linter and deviation detector bindings

const std = @import("std");
const mem = std.mem;

// Severity levels
pub const SEVERITY_ERROR = 0;
pub const SEVERITY_WARNING = 1;
pub const SEVERITY_NOTICE = 2;
pub const SEVERITY_INFO = 3;

// Deviation types
pub const DEVIATION_NAMING = 0;
pub const DEVIATION_STYLE = 1;
pub const DEVIATION_SECURITY = 2;
pub const DEVIATION_PERFORMANCE = 3;
pub const DEVIATION_DEPRECATED = 4;

// Result codes
pub const RESULT_SUCCESS = 0;
pub const RESULT_PARSE_ERROR = 1;
pub const RESULT_FILE_NOT_FOUND = 2;
pub const RESULT_INVALID_INPUT = 3;

// Lint issue struct
pub const LintIssue = extern struct {
    file: [256]u8,
    line: u32,
    column: u32,
    severity: u32,
    code: [32]u8,
    message: [512]u8,
    suggestion: [512]u8,
};

// Lint PHP file for syntax and style issues
pub export fn sanctify_lint_file(
    file_path: [*c]const u8,
    out_issues: [*c]LintIssue,
    max_issues: usize,
    out_count: [*c]usize,
) callconv(.C) i32 {
    if (file_path == null or out_issues == null) {
        return RESULT_INVALID_INPUT;
    }

    if (out_count) |count| {
        count.* = 0;  // Stub — would parse and lint actual PHP file
    }
    return RESULT_SUCCESS;
}

// Detect deviations from PHP best practices
pub export fn sanctify_detect_deviations(
    file_path: [*c]const u8,
    out_deviations: [*c]u32,
    max_deviations: usize,
    out_count: [*c]usize,
) callconv(.C) i32 {
    if (file_path == null or out_deviations == null) {
        return RESULT_INVALID_INPUT;
    }

    if (out_count) |count| {
        count.* = 0;  // Stub — would detect deviations
    }
    return RESULT_SUCCESS;
}

// Analyze entire PHP file
pub export fn sanctify_analyze_file(
    file_path: [*c]const u8,
    out_result: [*c]u8,
    out_len: usize,
) callconv(.C) i32 {
    if (file_path == null or out_result == null) {
        return RESULT_FILE_NOT_FOUND;
    }

    const analysis = "File analysis placeholder";
    if (out_len > 0) {
        const copy_len = @min(analysis.len, out_len - 1);
        @memcpy(out_result[0..copy_len], analysis[0..copy_len]);
        out_result[copy_len] = 0;
        return RESULT_SUCCESS;
    }
    return RESULT_INVALID_INPUT;
}

// Check a code snippet for issues
pub export fn sanctify_check_snippet(
    snippet: [*c]const u8,
    out_issues: [*c]LintIssue,
    max_issues: usize,
    out_count: [*c]usize,
) callconv(.C) i32 {
    if (snippet == null) {
        return RESULT_INVALID_INPUT;
    }

    if (out_count) |count| {
        count.* = 0;  // Stub — would check snippet
    }
    return RESULT_SUCCESS;
}

// Validate PHP syntax
pub export fn sanctify_validate_syntax(
    code: [*c]const u8,
) callconv(.C) i32 {
    if (code == null) {
        return RESULT_INVALID_INPUT;
    }
    // Stub — would validate PHP syntax
    return RESULT_SUCCESS;
}
