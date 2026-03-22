// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Burble-Admin-MCP Cartridge — V-lang adapter layer.
//
// Bridges Burble's Elixir/Phoenix HTTP API to BoJ's MCP tools via the
// BoJ triple adapter pattern. Provides MCP tools for monitoring, managing,
// and configuring the Burble voice platform. All communication is over
// HTTP to the Phoenix server — no FFI calls.

module burble_admin_adapter

import json
import net.http

// ===================================================================
// MCP Tool definitions
// ===================================================================

// MCP tool metadata for BoJ cartridge discovery.
pub const tools = [
	ToolDef{
		name: 'check_health'
		description: 'Check Burble server health status'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'list_rooms'
		description: 'List all active voice rooms with participant counts'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'create_room'
		description: 'Create a new voice room'
		input_schema: '{"type":"object","properties":{"name":{"type":"string"},"max_participants":{"type":"integer","default":16}},"required":["name"]}'
	},
	ToolDef{
		name: 'close_room'
		description: 'Close an active voice room and disconnect all participants'
		input_schema: '{"type":"object","properties":{"room_id":{"type":"string"}},"required":["room_id"]}'
	},
	ToolDef{
		name: 'kick_user'
		description: 'Remove a user from a voice room'
		input_schema: '{"type":"object","properties":{"room_id":{"type":"string"},"user_id":{"type":"string"}},"required":["room_id","user_id"]}'
	},
	ToolDef{
		name: 'get_config'
		description: 'Retrieve current Burble server configuration (TOML format)'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'update_config'
		description: 'Update Burble server configuration'
		input_schema: '{"type":"object","properties":{"config_json":{"type":"string","description":"JSON-encoded config key-value pairs to update"}},"required":["config_json"]}'
	},
	ToolDef{
		name: 'voice_stats'
		description: 'Get WebRTC voice quality statistics (bandwidth, jitter, packet loss, codec)'
		input_schema: '{"type":"object","properties":{}}'
	},
	ToolDef{
		name: 'toggle_recording'
		description: 'Toggle recording on/off for a voice room'
		input_schema: '{"type":"object","properties":{"room_id":{"type":"string"}},"required":["room_id"]}'
	},
	ToolDef{
		name: 'node_status'
		description: 'Get BEAM node information (name, uptime, connections, memory)'
		input_schema: '{"type":"object","properties":{}}'
	},
]

struct ToolDef {
	name         string
	description  string
	input_schema string
}

// ===================================================================
// Adapter lifecycle
// ===================================================================

// BurbleAdminAdapter holds the connection state for communicating with
// the Burble Phoenix API over HTTP.
struct BurbleAdminAdapter {
mut:
	base_url string
}

// Create a new adapter instance.
// The default base URL targets Burble's Phoenix server on port 4000.
pub fn new_adapter(base_url string) BurbleAdminAdapter {
	url := if base_url.len > 0 { base_url } else { 'http://[::1]:4000' }
	return BurbleAdminAdapter{
		base_url: url
	}
}

// ===================================================================
// MCP tool dispatch
// ===================================================================

// Dispatch an MCP tool invocation.
// Called by BoJ's cartridge router with the tool name and JSON arguments.
pub fn (mut a BurbleAdminAdapter) invoke(tool_name string, args_json string) string {
	return match tool_name {
		'check_health' { a.handle_check_health() }
		'list_rooms' { a.handle_list_rooms() }
		'create_room' { a.handle_create_room(args_json) }
		'close_room' { a.handle_close_room(args_json) }
		'kick_user' { a.handle_kick_user(args_json) }
		'get_config' { a.handle_get_config() }
		'update_config' { a.handle_update_config(args_json) }
		'voice_stats' { a.handle_voice_stats() }
		'toggle_recording' { a.handle_toggle_recording(args_json) }
		'node_status' { a.handle_node_status() }
		else { '{"error":"unknown tool: ${tool_name}"}' }
	}
}

// ===================================================================
// HTTP helpers
// ===================================================================

// Perform a GET request against the Burble API and return the response body.
fn (a &BurbleAdminAdapter) http_get(path string) string {
	resp := http.get('${a.base_url}${path}') or {
		return '{"error":"HTTP GET failed for ${path}: ${err.msg()}"}'
	}
	if resp.status_code < 200 || resp.status_code >= 300 {
		return '{"error":"HTTP ${resp.status_code} from ${path}: ${resp.body}"}'
	}
	return resp.body
}

// Perform a POST request with a JSON body against the Burble API.
fn (a &BurbleAdminAdapter) http_post(path string, body string) string {
	resp := http.post_json('${a.base_url}${path}', body) or {
		return '{"error":"HTTP POST failed for ${path}: ${err.msg()}"}'
	}
	if resp.status_code < 200 || resp.status_code >= 300 {
		return '{"error":"HTTP ${resp.status_code} from ${path}: ${resp.body}"}'
	}
	return resp.body
}

// Perform a PUT request with a JSON body against the Burble API.
fn (a &BurbleAdminAdapter) http_put(path string, body string) string {
	resp := http.fetch(
		url: '${a.base_url}${path}'
		method: .put
		header: http.new_header_from_map({
			http.CommonHeader.content_type: 'application/json'
		})
		data: body
	) or {
		return '{"error":"HTTP PUT failed for ${path}: ${err.msg()}"}'
	}
	if resp.status_code < 200 || resp.status_code >= 300 {
		return '{"error":"HTTP ${resp.status_code} from ${path}: ${resp.body}"}'
	}
	return resp.body
}

// Perform a DELETE request against the Burble API.
fn (a &BurbleAdminAdapter) http_delete(path string) string {
	resp := http.fetch(
		url: '${a.base_url}${path}'
		method: .delete
	) or {
		return '{"error":"HTTP DELETE failed for ${path}: ${err.msg()}"}'
	}
	if resp.status_code < 200 || resp.status_code >= 300 {
		return '{"error":"HTTP ${resp.status_code} from ${path}: ${resp.body}"}'
	}
	return resp.body
}

// ===================================================================
// Tool handlers
// ===================================================================

// check_health — GET /api/health
// Returns the overall health status of the Burble server.
fn (a &BurbleAdminAdapter) handle_check_health() string {
	return a.http_get('/api/health')
}

// list_rooms — GET /api/rooms
// Returns all active voice rooms with participant counts.
fn (a &BurbleAdminAdapter) handle_list_rooms() string {
	return a.http_get('/api/rooms')
}

// create_room — POST /api/rooms {name, max_participants}
// Creates a new voice room on the Burble server.
fn (a &BurbleAdminAdapter) handle_create_room(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON: ${err.msg()}"}'
	}
	name := (parsed['name'] or { return '{"error":"missing required field: name"}' }).str()
	max_participants := (parsed['max_participants'] or { json.Any(16) }).int()

	body := json.encode({
		'name':             json.Any(name)
		'max_participants': json.Any(max_participants)
	})
	return a.http_post('/api/rooms', body)
}

// close_room — DELETE /api/rooms/{room_id}
// Closes a voice room and disconnects all participants.
fn (a &BurbleAdminAdapter) handle_close_room(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON: ${err.msg()}"}'
	}
	room_id := (parsed['room_id'] or { return '{"error":"missing required field: room_id"}' }).str()
	return a.http_delete('/api/rooms/${room_id}')
}

// kick_user — POST /api/rooms/{room_id}/kick {user_id}
// Removes a specific user from a voice room.
fn (a &BurbleAdminAdapter) handle_kick_user(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON: ${err.msg()}"}'
	}
	room_id := (parsed['room_id'] or { return '{"error":"missing required field: room_id"}' }).str()
	user_id := (parsed['user_id'] or { return '{"error":"missing required field: user_id"}' }).str()

	body := json.encode({
		'user_id': json.Any(user_id)
	})
	return a.http_post('/api/rooms/${room_id}/kick', body)
}

// get_config — GET /api/config
// Retrieves the current server configuration in TOML format.
fn (a &BurbleAdminAdapter) handle_get_config() string {
	return a.http_get('/api/config')
}

// update_config — PUT /api/config {config_json}
// Updates the Burble server configuration with the provided key-value pairs.
fn (a &BurbleAdminAdapter) handle_update_config(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON: ${err.msg()}"}'
	}
	config_json := (parsed['config_json'] or {
		return '{"error":"missing required field: config_json"}'
	}).str()
	return a.http_put('/api/config', config_json)
}

// voice_stats — GET /api/stats
// Returns WebRTC quality stats: bandwidth, jitter, packet loss, codec info.
fn (a &BurbleAdminAdapter) handle_voice_stats() string {
	return a.http_get('/api/stats')
}

// toggle_recording — POST /api/rooms/{room_id}/recording
// Toggles recording on or off for the specified voice room.
fn (a &BurbleAdminAdapter) handle_toggle_recording(args_json string) string {
	parsed := json.decode(map[string]json.Any, args_json) or {
		return '{"error":"invalid JSON: ${err.msg()}"}'
	}
	room_id := (parsed['room_id'] or { return '{"error":"missing required field: room_id"}' }).str()
	return a.http_post('/api/rooms/${room_id}/recording', '{}')
}

// node_status — GET /api/node
// Returns BEAM node info: name, uptime, connections, memory usage.
fn (a &BurbleAdminAdapter) handle_node_status() string {
	return a.http_get('/api/node')
}
