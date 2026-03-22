// SPDX-License-Identifier: AGPL-3.0-or-later
// (PMPL-1.0-or-later preferred; AGPL-3.0-or-later required for IDApTIK — co-developed project exception)
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// IDApTIK-Admin-MCP Cartridge — V-lang adapter layer.
//
// Bridges the IDApTIK game server management WebSocket API (port 9101)
// to MCP tools via the BoJ triple adapter pattern. Provides tools for
// monitoring, configuring, and managing IDApTIK co-op stealth game sessions.
//
// IDApTIK is an asymmetric co-op stealth game:
//   - Jessica: platformer operative (6 subclasses, SBS agent — NOT a hacker)
//   - Q: CCTV/blueprints coordinator (cert tree, surveillance specialist)
// Game server: port 9100 (game), port 9101 (WebSocket management API).
// Containers managed via Podman.
//
// NOTE: IDApTIK uses AGPL-3.0-or-later license (exception to the PMPL rule).
// This is because IDApTIK is co-developed with the author's son and uses
// a Mustfile to enforce the AGPL licensing requirement.

module idaptik_admin_adapter

import json
import net.http

// ======================================================================
// MCP Tool definitions
// ======================================================================

// MCP tool metadata for BoJ cartridge discovery.
// 10 tools covering IDApTIK server lifecycle, session management,
// configuration, level packs, training grounds, and player statistics.
pub const tools = [
	ToolDef{
		name: 'server_status'
		description: 'Get IDApTIK server running state, player count, current level, and uptime'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'list_sessions'
		description: 'List active IDApTIK game sessions with Jessica/Q player pairs'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'create_session'
		description: 'Create a new IDApTIK co-op session with specified difficulty, level pack, and asymmetric mode'
		input_schema: '{"type":"object","properties":{"difficulty":{"type":"string","enum":["easy","normal","hard","nightmare"],"default":"normal"},"level_pack":{"type":"string","description":"Level pack identifier"},"asymmetric_mode":{"type":"string","enum":["standard","training","spectator"],"default":"standard"}},"required":["level_pack"]}'
	},
	ToolDef{
		name: 'end_session'
		description: 'End an active IDApTIK game session by session ID'
		input_schema: '{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}'
	},
	ToolDef{
		name: 'get_config'
		description: 'Get current IDApTIK server configuration in A2ML format'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'update_config'
		description: 'Apply configuration changes to the IDApTIK server'
		input_schema: '{"type":"object","properties":{"changes":{"type":"object","description":"Key-value pairs of config changes to apply"}},"required":["changes"]}'
	},
	ToolDef{
		name: 'list_level_packs'
		description: 'List all available IDApTIK level packs with metadata'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'toggle_training'
		description: 'Enable or disable IDApTIK training grounds mode'
		input_schema: '{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"]}'
	},
	ToolDef{
		name: 'player_stats'
		description: 'Get Jessica/Q player performance stats for a given session'
		input_schema: '{"type":"object","properties":{"session_id":{"type":"string"}},"required":["session_id"]}'
	},
	ToolDef{
		name: 'server_action'
		description: 'Execute a lifecycle action on the IDApTIK server container via Podman (start/stop/restart)'
		input_schema: '{"type":"object","properties":{"action":{"type":"string","enum":["start","stop","restart"]}},"required":["action"]}'
	},
]

// ToolDef holds MCP tool metadata for BoJ discovery.
struct ToolDef {
	name         string
	description  string
	input_schema string
}

// ======================================================================
// Adapter lifecycle
// ======================================================================

// IdaptikAdminAdapter bridges the IDApTIK WebSocket management API
// to BoJ MCP tool invocations. Communicates with the game server's
// REST management endpoints on port 9101.
struct IdaptikAdminAdapter {
mut:
	initialized bool
	base_url    string
}

// Create a new adapter instance.
// Defaults to http://[::1]:9101 (IPv6 loopback, IDApTIK management port).
pub fn new_adapter(base_url string) IdaptikAdminAdapter {
	url := if base_url.len > 0 { base_url } else { 'http://[::1]:9101' }
	return IdaptikAdminAdapter{
		initialized: false
		base_url: url
	}
}

// Initialize the adapter. Validates connectivity to the IDApTIK management API.
pub fn (mut a IdaptikAdminAdapter) init() !void {
	// Verify the management API is reachable with a health check.
	resp := http.get('${a.base_url}/api/status') or {
		return error('IDApTIK management API unreachable at ${a.base_url}: ${err}')
	}
	if resp.status_code != 200 {
		return error('IDApTIK management API returned status ${resp.status_code}')
	}
	a.initialized = true
}

// Shutdown the adapter and release resources.
pub fn (mut a IdaptikAdminAdapter) shutdown() {
	a.initialized = false
}

// ======================================================================
// MCP tool dispatch
// ======================================================================

// Dispatch an MCP tool invocation.
// Called by BoJ's cartridge router with the tool name and JSON arguments.
pub fn (mut a IdaptikAdminAdapter) invoke(tool_name string, args_json string) string {
	if !a.initialized {
		return '{"error":"IDApTIK adapter not initialized"}'
	}

	return match tool_name {
		'server_status' { a.handle_server_status() }
		'list_sessions' { a.handle_list_sessions() }
		'create_session' { a.handle_create_session(args_json) }
		'end_session' { a.handle_end_session(args_json) }
		'get_config' { a.handle_get_config() }
		'update_config' { a.handle_update_config(args_json) }
		'list_level_packs' { a.handle_list_level_packs() }
		'toggle_training' { a.handle_toggle_training(args_json) }
		'player_stats' { a.handle_player_stats(args_json) }
		'server_action' { a.handle_server_action(args_json) }
		else { '{"error":"unknown tool: ${tool_name}"}' }
	}
}

// ======================================================================
// Tool handlers — each maps to an IDApTIK management API endpoint
// ======================================================================

// GET /api/status — server running state, player count, current level, uptime.
fn (a &IdaptikAdminAdapter) handle_server_status() string {
	resp := http.get('${a.base_url}/api/status') or {
		return '{"error":"failed to reach IDApTIK status endpoint: ${err}"}'
	}
	return resp.body
}

// GET /api/sessions — active game sessions with Jessica/Q player pairs.
fn (a &IdaptikAdminAdapter) handle_list_sessions() string {
	resp := http.get('${a.base_url}/api/sessions') or {
		return '{"error":"failed to list sessions: ${err}"}'
	}
	return resp.body
}

// POST /api/sessions — create a new co-op session.
// Expects: { "difficulty": "normal", "level_pack": "...", "asymmetric_mode": "standard" }
fn (a &IdaptikAdminAdapter) handle_create_session(args_json string) string {
	resp := http.post('${a.base_url}/api/sessions', args_json) or {
		return '{"error":"failed to create session: ${err}"}'
	}
	if resp.status_code != 201 && resp.status_code != 200 {
		return '{"error":"create session returned status ${resp.status_code}","body":${resp.body}}'
	}
	return resp.body
}

// DELETE /api/sessions/{session_id} — end an active session.
fn (a &IdaptikAdminAdapter) handle_end_session(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON"}'
	}
	session_id := parsed['session_id'] or { return '{"error":"missing session_id"}' }.str()

	mut req := http.Request{
		method: .delete
		url: '${a.base_url}/api/sessions/${session_id}'
	}
	resp := req.do() or {
		return '{"error":"failed to end session: ${err}"}'
	}
	return resp.body
}

// GET /api/config — current server configuration (A2ML format).
fn (a &IdaptikAdminAdapter) handle_get_config() string {
	resp := http.get('${a.base_url}/api/config') or {
		return '{"error":"failed to get config: ${err}"}'
	}
	return resp.body
}

// PUT /api/config — apply configuration changes.
// Expects: { "changes": { "key": "value", ... } }
fn (a &IdaptikAdminAdapter) handle_update_config(args_json string) string {
	mut req := http.Request{
		method: .put
		url: '${a.base_url}/api/config'
		data: args_json
	}
	resp := req.do() or {
		return '{"error":"failed to update config: ${err}"}'
	}
	return resp.body
}

// GET /api/levels — available level packs.
fn (a &IdaptikAdminAdapter) handle_list_level_packs() string {
	resp := http.get('${a.base_url}/api/levels') or {
		return '{"error":"failed to list level packs: ${err}"}'
	}
	return resp.body
}

// POST /api/training — enable/disable training grounds.
// Expects: { "enabled": true|false }
fn (a &IdaptikAdminAdapter) handle_toggle_training(args_json string) string {
	resp := http.post('${a.base_url}/api/training', args_json) or {
		return '{"error":"failed to toggle training: ${err}"}'
	}
	return resp.body
}

// GET /api/sessions/{session_id}/stats — Jessica/Q player performance stats.
fn (a &IdaptikAdminAdapter) handle_player_stats(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON"}'
	}
	session_id := parsed['session_id'] or { return '{"error":"missing session_id"}' }.str()

	resp := http.get('${a.base_url}/api/sessions/${session_id}/stats') or {
		return '{"error":"failed to get player stats: ${err}"}'
	}
	return resp.body
}

// POST /api/action — lifecycle action on the IDApTIK Podman container.
// Expects: { "action": "start"|"stop"|"restart" }
// Delegates to Podman container management for the idaptik-server container.
fn (a &IdaptikAdminAdapter) handle_server_action(args_json string) string {
	resp := http.post('${a.base_url}/api/action', args_json) or {
		return '{"error":"failed to execute server action: ${err}"}'
	}
	if resp.status_code != 200 {
		return '{"error":"server action returned status ${resp.status_code}","body":${resp.body}}'
	}
	return resp.body
}
