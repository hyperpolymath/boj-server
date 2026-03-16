// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// notion_mcp_adapter.v — V-lang REST adapter for the Notion REST API cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes REST endpoints for all 16 Notion actions, connection management,
// rate-limit inspection, workspace info, and session metrics.

module notion_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lnotion_mcp

fn C.notion_mcp_can_transition(from int, to int) int
fn C.notion_mcp_authenticate(token &u8) int
fn C.notion_mcp_disconnect(slot_idx int) int
fn C.notion_mcp_session_state(slot_idx int) int
fn C.notion_mcp_workspace(slot_idx int, out_buf &u8, out_cap int, out_len &int) int
fn C.notion_mcp_rate_count(slot_idx int) int
fn C.notion_mcp_page_count(slot_idx int) int
fn C.notion_mcp_actions_performed(slot_idx int) int
fn C.notion_mcp_rate_recover(slot_idx int) int
fn C.notion_mcp_api_call(slot_idx int, action_id int, params &u8, out_buf &u8, out_cap int, out_len &int) int
fn C.notion_mcp_reset()

// ---------------------------------------------------------------------------
// Connection state enum (mirrors Idris2 ConnState / Zig ConnState)
// ---------------------------------------------------------------------------

enum ConnState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
}

// ---------------------------------------------------------------------------
// Notion action IDs (mirrors Idris2 NotionAction / Zig NotionAction)
// ---------------------------------------------------------------------------

enum NotionActionId {
	search_pages    = 0
	get_page        = 1
	create_page     = 2
	update_page     = 3
	delete_page     = 4
	get_database    = 5
	query_database  = 6
	create_database = 7
	list_blocks     = 8
	get_block       = 9
	append_blocks   = 10
	delete_block    = 11
	list_users      = 12
	get_user        = 13
	create_comment  = 14
	list_comments   = 15
}

// ---------------------------------------------------------------------------
// Helper: decode connection state integer to label
// ---------------------------------------------------------------------------

fn state_label(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'rate_limited' }
		3 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Response from authenticate / connect operations.
struct ConnectResponse {
	slot      int
	state     string
	workspace string
}

/// Response from state queries.
struct StateResponse {
	slot  int
	state string
}

/// Response from transition validation.
struct TransitionResponse {
	from  int
	to    int
	valid bool
}

/// Response from Notion API operations (generic JSON envelope).
struct ApiResponse {
	slot   int
	action string
	body   string
}

/// Rate-limit status for the session.
struct RateLimitStatus {
	slot    int
	count   int
	budget  int
}

/// Session metrics for panel data sources.
struct SessionMetrics {
	slot              int
	state             string
	workspace         string
	page_count        int
	actions_performed int
	rate_count        int
	rate_budget       int
}

// ---------------------------------------------------------------------------
// Adapter functions — connection lifecycle
// ---------------------------------------------------------------------------

/// Authenticate with Notion using an integration token (Bearer).
/// The token should be retrieved from vault-mcp before calling.
pub fn authenticate(token string) !ConnectResponse {
	slot := C.notion_mcp_authenticate(token.str)
	if slot == -1 {
		return error('no session slots available')
	}
	if slot == -3 {
		return error('empty token')
	}
	if slot == -4 {
		return error('token too short (Notion integration tokens start with secret_ or ntn_)')
	}
	if slot < 0 {
		return error('authentication failed (code ${slot})')
	}

	mut ws_buf := []u8{len: 256}
	mut ws_len := 0
	C.notion_mcp_workspace(slot, ws_buf.data, 256, &ws_len)
	workspace := if ws_len > 0 { ws_buf[..ws_len].bytestr() } else { '' }

	return ConnectResponse{
		slot: slot
		state: 'authenticated'
		workspace: workspace
	}
}

/// Disconnect a session gracefully.
pub fn disconnect(slot int) !string {
	result := C.notion_mcp_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for disconnect') }
		else { return error('disconnect failed (code ${result})') }
	}
}

/// Get the current connection state of a session.
pub fn session_state(slot int) StateResponse {
	s := C.notion_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

/// Check if a state transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.notion_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Recover from a rate-limited state.
pub fn rate_recover(slot int) !string {
	result := C.notion_mcp_rate_recover(slot)
	return match result {
		0 { 'recovered slot ${slot} to authenticated' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('not in rate_limited state') }
		else { return error('recovery failed (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Adapter functions — Notion API actions (all 16)
// ---------------------------------------------------------------------------

/// Generic API call by action ID. Covers all 16 actions.
pub fn api_call(slot int, action_id int, params string) !ApiResponse {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	params_ptr := if params.len > 0 { params.str } else { unsafe { nil } }
	result := C.notion_mcp_api_call(slot, action_id, params_ptr, buf.data, 8192, &out_len)
	if result == -6 {
		return error('unknown action id ${action_id}')
	}
	if result == -5 {
		return error('rate limited')
	}
	if result < 0 {
		return error('api_call failed (code ${result})')
	}

	action_name := match action_id {
		0 { 'search_pages' }
		1 { 'get_page' }
		2 { 'create_page' }
		3 { 'update_page' }
		4 { 'delete_page' }
		5 { 'get_database' }
		6 { 'query_database' }
		7 { 'create_database' }
		8 { 'list_blocks' }
		9 { 'get_block' }
		10 { 'append_blocks' }
		11 { 'delete_block' }
		12 { 'list_users' }
		13 { 'get_user' }
		14 { 'create_comment' }
		15 { 'list_comments' }
		else { 'unknown' }
	}
	return ApiResponse{ slot: slot, action: action_name, body: buf[..out_len].bytestr() }
}

// ---------------------------------------------------------------------------
// Convenience wrappers for each action (delegate to api_call)
// ---------------------------------------------------------------------------

/// Search pages by query string.
pub fn search_pages(slot int, query string) !ApiResponse {
	return api_call(slot, int(NotionActionId.search_pages), '{"query":"${query}"}')
}

/// Get a page by ID.
pub fn get_page(slot int, page_id string) !ApiResponse {
	return api_call(slot, int(NotionActionId.get_page), '{"page_id":"${page_id}"}')
}

/// Create a new page.
pub fn create_page(slot int, parent_id string, title string) !ApiResponse {
	return api_call(slot, int(NotionActionId.create_page), '{"parent":{"page_id":"${parent_id}"},"properties":{"title":{"title":[{"text":{"content":"${title}"}}]}}}')
}

/// Update page properties.
pub fn update_page(slot int, page_id string, properties string) !ApiResponse {
	return api_call(slot, int(NotionActionId.update_page), '{"page_id":"${page_id}","properties":${properties}}')
}

/// Delete (archive) a page.
pub fn delete_page(slot int, page_id string) !ApiResponse {
	return api_call(slot, int(NotionActionId.delete_page), '{"page_id":"${page_id}","archived":true}')
}

/// Get a database by ID.
pub fn get_database(slot int, database_id string) !ApiResponse {
	return api_call(slot, int(NotionActionId.get_database), '{"database_id":"${database_id}"}')
}

/// Query a database with optional filter and sorts.
pub fn query_database(slot int, database_id string, filter string) !ApiResponse {
	return api_call(slot, int(NotionActionId.query_database), '{"database_id":"${database_id}","filter":${filter}}')
}

/// Create a new database.
pub fn create_database(slot int, parent_id string, title string, properties string) !ApiResponse {
	return api_call(slot, int(NotionActionId.create_database), '{"parent":{"page_id":"${parent_id}"},"title":[{"text":{"content":"${title}"}}],"properties":${properties}}')
}

/// List child blocks of a block.
pub fn list_blocks(slot int, block_id string) !ApiResponse {
	return api_call(slot, int(NotionActionId.list_blocks), '{"block_id":"${block_id}"}')
}

/// Get a block by ID.
pub fn get_block(slot int, block_id string) !ApiResponse {
	return api_call(slot, int(NotionActionId.get_block), '{"block_id":"${block_id}"}')
}

/// Append child blocks to a block.
pub fn append_blocks(slot int, block_id string, children string) !ApiResponse {
	return api_call(slot, int(NotionActionId.append_blocks), '{"block_id":"${block_id}","children":${children}}')
}

/// Delete a block.
pub fn delete_block(slot int, block_id string) !ApiResponse {
	return api_call(slot, int(NotionActionId.delete_block), '{"block_id":"${block_id}"}')
}

/// List users in the workspace.
pub fn list_users(slot int) !ApiResponse {
	return api_call(slot, int(NotionActionId.list_users), '')
}

/// Get a user by ID.
pub fn get_user(slot int, user_id string) !ApiResponse {
	return api_call(slot, int(NotionActionId.get_user), '{"user_id":"${user_id}"}')
}

/// Create a comment on a page or discussion.
pub fn create_comment(slot int, parent_id string, text string) !ApiResponse {
	return api_call(slot, int(NotionActionId.create_comment), '{"parent":{"page_id":"${parent_id}"},"rich_text":[{"text":{"content":"${text}"}}]}')
}

/// List comments on a block.
pub fn list_comments(slot int, block_id string) !ApiResponse {
	return api_call(slot, int(NotionActionId.list_comments), '{"block_id":"${block_id}"}')
}

// ---------------------------------------------------------------------------
// Adapter functions — metrics and rate limits (for PanLL panels)
// ---------------------------------------------------------------------------

/// Get rate-limit status for a session.
pub fn rate_limit_status(slot int) RateLimitStatus {
	count := C.notion_mcp_rate_count(slot)
	return RateLimitStatus{
		slot: slot
		count: if count >= 0 { count } else { 0 }
		budget: 3
	}
}

/// Get full session metrics (state, workspace, pages, rate limits).
pub fn session_metrics(slot int) SessionMetrics {
	st := C.notion_mcp_session_state(slot)

	mut ws_buf := []u8{len: 256}
	mut ws_len := 0
	C.notion_mcp_workspace(slot, ws_buf.data, 256, &ws_len)
	workspace := if ws_len > 0 { ws_buf[..ws_len].bytestr() } else { '' }

	pages := C.notion_mcp_page_count(slot)
	actions := C.notion_mcp_actions_performed(slot)
	rate := C.notion_mcp_rate_count(slot)

	return SessionMetrics{
		slot: slot
		state: state_label(st)
		workspace: workspace
		page_count: if pages >= 0 { pages } else { 0 }
		actions_performed: if actions >= 0 { actions } else { 0 }
		rate_count: if rate >= 0 { rate } else { 0 }
		rate_budget: 3
	}
}

/// Reset all sessions (test/debug use only).
pub fn reset() {
	C.notion_mcp_reset()
}
