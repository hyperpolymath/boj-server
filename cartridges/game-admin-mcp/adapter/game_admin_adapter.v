// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Game-Admin-MCP Cartridge — V-lang adapter layer.
//
// Bridges the GSA Zig FFI (libgsa.so) to REST/gRPC/GraphQL endpoints
// via the BoJ triple adapter pattern. Provides MCP tools for probing,
// configuring, and managing game servers.

module game_admin_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against libgsa built from GSA repo)
// ═══════════════════════════════════════════════════════════════════════

fn C.gossamer_gsa_init(verisimdb_url &u8, profiles_dir &u8) int
fn C.gossamer_gsa_shutdown() int
fn C.gossamer_gsa_probe(host &u8, port int) int
fn C.gossamer_gsa_extract_config(handle int, profile_id &u8) &u8
fn C.gossamer_gsa_server_action(handle int, action_json &u8) &u8
fn C.gossamer_gsa_get_logs(handle int, lines int) &u8
fn C.gossamer_gsa_list_profiles() &u8
fn C.gossamer_gsa_load_profiles(dir &u8) int
fn C.gossamer_gsa_verisimdb_query(vql &u8) &u8
fn C.gossamer_gsa_verisimdb_health() int
fn C.gossamer_gsa_verisimdb_drift(server_id &u8) &u8
fn C.gossamer_gsa_verisimdb_store(octad_json &u8) int
fn C.gossamer_gsa_last_error() &u8

// ═══════════════════════════════════════════════════════════════════════
// MCP Tool definitions
// ═══════════════════════════════════════════════════════════════════════

// MCP tool metadata for BoJ cartridge discovery.
pub const tools = [
	ToolDef{
		name: 'probe_server'
		description: 'Probe a game server by host and port to identify game type and extract config'
		input_schema: '{"type":"object","properties":{"host":{"type":"string"},"port":{"type":"integer","default":27015}},"required":["host"]}'
	},
	ToolDef{
		name: 'list_servers'
		description: 'List all managed game servers from VeriSimDB'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'get_config'
		description: 'Get current config for a managed server as A2ML'
		input_schema: '{"type":"object","properties":{"server_id":{"type":"string"}},"required":["server_id"]}'
	},
	ToolDef{
		name: 'set_config'
		description: 'Apply config changes to a managed server'
		input_schema: '{"type":"object","properties":{"server_id":{"type":"string"},"changes":{"type":"array","items":{"type":"object","properties":{"key":{"type":"string"},"value":{"type":"string"}}}}},"required":["server_id","changes"]}'
	},
	ToolDef{
		name: 'server_action'
		description: 'Execute an action on a game server (start/stop/restart/status/logs)'
		input_schema: '{"type":"object","properties":{"server_id":{"type":"string"},"action":{"type":"string","enum":["start","stop","restart","status","logs","update","backup","validate"]}},"required":["server_id","action"]}'
	},
	ToolDef{
		name: 'drift_status'
		description: 'Get config drift status across all managed servers'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'list_profiles'
		description: 'List all available game profiles (supported game server types)'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'search_configs'
		description: 'Search across all server configs using VQL text search'
		input_schema: '{"type":"object","properties":{"query":{"type":"string"},"mode":{"type":"string","enum":["text","vector","vql"],"default":"text"}},"required":["query"]}'
	},
	ToolDef{
		name: 'last_probe'
		description: 'Get the result of the most recent server probe'
		input_schema: '{"type":"object","properties":{}}'
	},
]

struct ToolDef {
	name        string
	description string
	input_schema string
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter lifecycle
// ═══════════════════════════════════════════════════════════════════════

struct GameAdminAdapter {
mut:
	initialized bool
	verisimdb_url string
	profiles_dir  string
	last_probe_result string
}

// Create a new adapter instance.
pub fn new_adapter(verisimdb_url string, profiles_dir string) GameAdminAdapter {
	return GameAdminAdapter{
		initialized: false
		verisimdb_url: verisimdb_url
		profiles_dir: profiles_dir
		last_probe_result: '{}'
	}
}

// Initialize the GSA FFI layer.
pub fn (mut a GameAdminAdapter) init() !void {
	result := C.gossamer_gsa_init(a.verisimdb_url.str, a.profiles_dir.str)
	if result != 0 {
		return error('GSA init failed: ${unsafe { cstring_to_vstring(C.gossamer_gsa_last_error()) }}')
	}
	a.initialized = true
}

// Shutdown the GSA FFI layer.
pub fn (mut a GameAdminAdapter) shutdown() {
	if a.initialized {
		C.gossamer_gsa_shutdown()
		a.initialized = false
	}
}

// ═══════════════════════════════════════════════════════════════════════
// MCP tool dispatch
// ═══════════════════════════════════════════════════════════════════════

// Dispatch an MCP tool invocation.
// Called by BoJ's cartridge router with the tool name and JSON arguments.
pub fn (mut a GameAdminAdapter) invoke(tool_name string, args_json string) string {
	if !a.initialized {
		return '{"error":"GSA adapter not initialized"}'
	}

	return match tool_name {
		'probe_server' { a.handle_probe(args_json) }
		'list_servers' { a.handle_list_servers() }
		'get_config' { a.handle_get_config(args_json) }
		'set_config' { a.handle_set_config(args_json) }
		'server_action' { a.handle_server_action(args_json) }
		'drift_status' { a.handle_drift_status() }
		'list_profiles' { a.handle_list_profiles() }
		'search_configs' { a.handle_search(args_json) }
		'last_probe' { a.last_probe_result }
		else { '{"error":"unknown tool: ${tool_name}"}' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tool handlers
// ═══════════════════════════════════════════════════════════════════════

fn (mut a GameAdminAdapter) handle_probe(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON"}'
	}
	host := parsed['host'] or { return '{"error":"missing host"}' }.str()
	port := (parsed['port'] or { json.Any(27015) }).int()

	result := C.gossamer_gsa_probe(host.str, port)
	if result < 0 {
		err_msg := unsafe { cstring_to_vstring(C.gossamer_gsa_last_error()) }
		return '{"error":"probe failed: ${err_msg}"}'
	}

	// Extract config using the probed handle
	config := unsafe { cstring_to_vstring(C.gossamer_gsa_extract_config(result, ''.str)) }
	a.last_probe_result = config
	return config
}

fn (a &GameAdminAdapter) handle_list_servers() string {
	vql := 'SELECT document, semantic, temporal FROM octads LIMIT 100'
	result := unsafe { cstring_to_vstring(C.gossamer_gsa_verisimdb_query(vql.str)) }
	if result.len == 0 {
		return '{"error":"VeriSimDB query failed"}'
	}
	return result
}

fn (a &GameAdminAdapter) handle_get_config(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON"}'
	}
	server_id := parsed['server_id'] or { return '{"error":"missing server_id"}' }.str()

	vql := "SELECT document FROM octads WHERE id = '${server_id}'"
	result := unsafe { cstring_to_vstring(C.gossamer_gsa_verisimdb_query(vql.str)) }
	return result
}

fn (a &GameAdminAdapter) handle_set_config(args_json string) string {
	// Delegate to GSA FFI — it handles VeriSimDB update + provenance
	result := unsafe { cstring_to_vstring(C.gossamer_gsa_server_action(0, args_json.str)) }
	return result
}

fn (a &GameAdminAdapter) handle_server_action(args_json string) string {
	result := unsafe { cstring_to_vstring(C.gossamer_gsa_server_action(0, args_json.str)) }
	if result.len == 0 {
		err_msg := unsafe { cstring_to_vstring(C.gossamer_gsa_last_error()) }
		return '{"error":"action failed: ${err_msg}"}'
	}
	return result
}

fn (a &GameAdminAdapter) handle_drift_status() string {
	health := C.gossamer_gsa_verisimdb_health()
	drift := unsafe { cstring_to_vstring(C.gossamer_gsa_verisimdb_drift(''.str)) }
	return '{"verisimdb_healthy":${health == 0},"drift":${drift}}'
}

fn (a &GameAdminAdapter) handle_list_profiles() string {
	result := unsafe { cstring_to_vstring(C.gossamer_gsa_list_profiles()) }
	return result
}

fn (a &GameAdminAdapter) handle_search(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON"}'
	}
	query := parsed['query'] or { return '{"error":"missing query"}' }.str()
	mode := (parsed['mode'] or { json.Any('text') }).str()

	vql := match mode {
		'text' { "SEARCH TEXT '${query}' LIMIT 50" }
		'vql' { query }
		else { "SEARCH TEXT '${query}' LIMIT 50" }
	}

	result := unsafe { cstring_to_vstring(C.gossamer_gsa_verisimdb_query(vql.str)) }
	return result
}
