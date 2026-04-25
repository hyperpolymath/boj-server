// SPDX-License-Identifier: PMPL-1.0-or-later
// Fireflag Cartridge FFI — Extension-to-MCP mapping bindings

const std = @import("std");
const mem = std.mem;

// Extension type constants
pub const EXT_VSCODE = 0;
pub const EXT_IDE = 1;
pub const EXT_DESKTOP = 2;
pub const EXT_CLI = 3;
pub const EXT_WEB = 4;
pub const EXT_LSP = 5;
pub const EXT_OTHER = 6;

// Result codes
pub const RESULT_SUCCESS = 0;
pub const RESULT_NOT_FOUND = 1;
pub const RESULT_INVALID_PATH = 2;
pub const RESULT_PARSE_ERROR = 3;

// MCP capability struct
pub const MCPCapability = extern struct {
    name: [128]u8,
    tool_name: [128]u8,
    description: [512]u8,
};

// Extension metadata struct
pub const ExtensionMetadata = extern struct {
    extension_id: [256]u8,
    extension_type: u32,
    name: [256]u8,
    description: [512]u8,
    version: [32]u8,
    num_tools: u32,
};

// Map an extension directory to available MCP tools
pub export fn fireflag_map_extension(
    extension_path: [*c]const u8,
    out_metadata: [*c]ExtensionMetadata,
    out_tools: [*c]MCPCapability,
    max_tools: usize,
    out_tool_count: [*c]usize,
) callconv(.C) i32 {
    if (extension_path == null or out_metadata == null) {
        return RESULT_INVALID_PATH;
    }

    if (out_tool_count) |count| {
        count.* = 0;  // Stub — would discover and map tools
    }
    return RESULT_SUCCESS;
}

// List all mapped extensions
pub export fn fireflag_list_mapped_extensions(
    out_extensions: [*c]ExtensionMetadata,
    max_extensions: usize,
    out_count: [*c]usize,
) callconv(.C) i32 {
    if (out_extensions == null) {
        return RESULT_INVALID_PATH;
    }

    if (out_count) |count| {
        count.* = 0;  // Stub — would enumerate mapped extensions
    }
    return RESULT_SUCCESS;
}

// Get MCP tools available for an extension
pub export fn fireflag_get_extension_tools(
    extension_id: [*c]const u8,
    out_tools: [*c]MCPCapability,
    max_tools: usize,
    out_count: [*c]usize,
) callconv(.C) i32 {
    if (extension_id == null or out_tools == null) {
        return RESULT_INVALID_PATH;
    }

    if (out_count) |count| {
        count.* = 0;  // Stub — would fetch tools for extension
    }
    return RESULT_SUCCESS;
}

// Validate extension configuration
pub export fn fireflag_validate_extension(
    extension_path: [*c]const u8,
    out_errors: [*c]u8,
    out_len: usize,
) callconv(.C) i32 {
    if (extension_path == null or out_errors == null) {
        return RESULT_INVALID_PATH;
    }

    // Stub — would validate extension structure
    if (out_len > 0) {
        out_errors[0] = 0;  // No errors (stub)
    }
    return RESULT_SUCCESS;
}

// Discover extensions in directory
pub export fn fireflag_discover_extensions(
    directory: [*c]const u8,
    out_extensions: [*c]ExtensionMetadata,
    max_extensions: usize,
    out_count: [*c]usize,
) callconv(.C) i32 {
    if (directory == null or out_extensions == null) {
        return RESULT_INVALID_PATH;
    }

    if (out_count) |count| {
        count.* = 0;  // Stub — would discover extensions
    }
    return RESULT_SUCCESS;
}

// Get extension type
pub export fn fireflag_get_extension_type(
    extension_path: [*c]const u8,
) callconv(.C) u32 {
    if (extension_path == null) {
        return EXT_OTHER;
    }
    // Stub — would detect extension type
    return EXT_OTHER;
}
