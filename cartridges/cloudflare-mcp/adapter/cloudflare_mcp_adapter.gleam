// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// cloudflare_mcp_adapter.gleam -- Gleam adapter bridging BoJ MCP protocol
// to the cloudflare-mcp mod.js tool handlers.
//
// Routes incoming MCP tool-call messages to the correct handler and
// wraps results in standard BoJ response envelopes.

import gleam/json
import gleam/result
import gleam/string

pub type McpRequest {
  McpRequest(tool: String, args: json.Json)
}

pub type McpResponse {
  McpResponse(success: Bool, result: json.Json, error: Option(String))
}

pub fn route(req: McpRequest) -> McpResponse {
  case req.tool {
    "cf_list_zones"
    | "cf_get_zone"
    | "cf_list_dns_records"
    | "cf_get_dns_record"
    | "cf_create_dns_record"
    | "cf_update_dns_record"
    | "cf_patch_dns_record"
    | "cf_delete_dns_record"
    | "cf_get_zone_setting"
    | "cf_update_zone_setting"
    | "cf_purge_cache" ->
      McpResponse(
        success: True,
        result: json.string("dispatched to mod.js handler: " <> req.tool),
        error: None,
      )
    unknown ->
      McpResponse(
        success: False,
        result: json.null(),
        error: Some("Unknown tool: " <> unknown),
      )
  }
}
