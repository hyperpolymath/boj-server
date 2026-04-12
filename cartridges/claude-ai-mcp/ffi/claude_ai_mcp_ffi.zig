// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Claude AI MCP cartridge FFI — stub implementation
// Full implementation uses the Anthropic API via the REST adapter layer.

const std = @import("std");

pub export fn claude_ai_mcp_version() [*:0]const u8 {
    return "0.1.0";
}

pub export fn claude_ai_mcp_health() c_int {
    return 0;
}
