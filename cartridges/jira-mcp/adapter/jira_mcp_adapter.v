// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// jira_mcp_adapter.v — V-lang REST adapter for the Jira Cloud REST API cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes REST endpoints for all 16 Jira actions, connection management,
// rate-limit inspection, instance info, and sprint progress metrics.

module jira_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -ljira_mcp

fn C.jira_mcp_can_transition(from int, to int) int
fn C.jira_mcp_authenticate(instance &u8, email &u8, api_token &u8) int
fn C.jira_mcp_disconnect(slot_idx int) int
fn C.jira_mcp_session_state(slot_idx int) int
fn C.jira_mcp_instance(slot_idx int, out_buf &u8, out_cap int, out_len &int) int
fn C.jira_mcp_rate_count(slot_idx int) int
fn C.jira_mcp_actions_performed(slot_idx int) int
fn C.jira_mcp_sprint_progress(slot_idx int) int
fn C.jira_mcp_rate_recover(slot_idx int) int
fn C.jira_mcp_api_call(slot_idx int, action_id int, params &u8, out_buf &u8, out_cap int, out_len &int) int
fn C.jira_mcp_reset()

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
// Jira action IDs (mirrors Idris2 JiraAction / Zig JiraAction)
// ---------------------------------------------------------------------------

enum JiraActionId {
	search_issues    = 0
	get_issue        = 1
	create_issue     = 2
	update_issue     = 3
	delete_issue     = 4
	add_comment      = 5
	list_projects    = 6
	get_project      = 7
	list_boards      = 8
	get_board        = 9
	list_sprints     = 10
	get_sprint       = 11
	transition_issue = 12
	assign_issue     = 13
	list_fields      = 14
	get_user         = 15
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
	slot     int
	state    string
	instance string
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

/// Response from Jira API operations (generic JSON envelope).
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
	instance          string
	actions_performed int
	sprint_progress   int
	rate_count        int
	rate_budget       int
}

// ---------------------------------------------------------------------------
// Adapter functions — connection lifecycle
// ---------------------------------------------------------------------------

/// Authenticate with Jira Cloud using Basic auth (email + Atlassian API token).
/// The credentials should be retrieved from vault-mcp before calling.
/// Note: uses Atlassian API Tokens, NOT app passwords.
pub fn authenticate(instance string, email string, api_token string) !ConnectResponse {
	slot := C.jira_mcp_authenticate(instance.str, email.str, api_token.str)
	if slot == -1 {
		return error('no session slots available')
	}
	if slot == -3 {
		return error('null argument (instance, email, or api_token)')
	}
	if slot == -4 {
		return error('credential too short')
	}
	if slot < 0 {
		return error('authentication failed (code ${slot})')
	}

	mut inst_buf := []u8{len: 256}
	mut inst_len := 0
	C.jira_mcp_instance(slot, inst_buf.data, 256, &inst_len)
	inst := if inst_len > 0 { inst_buf[..inst_len].bytestr() } else { '' }

	return ConnectResponse{
		slot: slot
		state: 'authenticated'
		instance: inst
	}
}

/// Disconnect a session gracefully.
pub fn disconnect(slot int) !string {
	result := C.jira_mcp_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for disconnect') }
		else { return error('disconnect failed (code ${result})') }
	}
}

/// Get the current connection state of a session.
pub fn session_state(slot int) StateResponse {
	s := C.jira_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

/// Check if a state transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.jira_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Recover from a rate-limited state.
pub fn rate_recover(slot int) !string {
	result := C.jira_mcp_rate_recover(slot)
	return match result {
		0 { 'recovered slot ${slot} to authenticated' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('not in rate_limited state') }
		else { return error('recovery failed (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Adapter functions — Jira API actions (all 16)
// ---------------------------------------------------------------------------

/// Generic API call by action ID. Covers all 16 actions.
pub fn api_call(slot int, action_id int, params string) !ApiResponse {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	params_ptr := if params.len > 0 { params.str } else { unsafe { nil } }
	result := C.jira_mcp_api_call(slot, action_id, params_ptr, buf.data, 8192, &out_len)
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
		0 { 'search_issues' }
		1 { 'get_issue' }
		2 { 'create_issue' }
		3 { 'update_issue' }
		4 { 'delete_issue' }
		5 { 'add_comment' }
		6 { 'list_projects' }
		7 { 'get_project' }
		8 { 'list_boards' }
		9 { 'get_board' }
		10 { 'list_sprints' }
		11 { 'get_sprint' }
		12 { 'transition_issue' }
		13 { 'assign_issue' }
		14 { 'list_fields' }
		15 { 'get_user' }
		else { 'unknown' }
	}
	return ApiResponse{ slot: slot, action: action_name, body: buf[..out_len].bytestr() }
}

// ---------------------------------------------------------------------------
// Convenience wrappers for each action (delegate to api_call)
// ---------------------------------------------------------------------------

/// Search issues using JQL.
pub fn search_issues(slot int, jql string) !ApiResponse {
	return api_call(slot, int(JiraActionId.search_issues), '{"jql":"${jql}"}')
}

/// Get a single issue by key or ID.
pub fn get_issue(slot int, issue_key string) !ApiResponse {
	return api_call(slot, int(JiraActionId.get_issue), '{"issueIdOrKey":"${issue_key}"}')
}

/// Create a new issue.
pub fn create_issue(slot int, project_key string, summary string, issue_type string) !ApiResponse {
	return api_call(slot, int(JiraActionId.create_issue), '{"fields":{"project":{"key":"${project_key}"},"summary":"${summary}","issuetype":{"name":"${issue_type}"}}}')
}

/// Update an existing issue.
pub fn update_issue(slot int, issue_key string, fields string) !ApiResponse {
	return api_call(slot, int(JiraActionId.update_issue), '{"issueIdOrKey":"${issue_key}","fields":${fields}}')
}

/// Delete an issue.
pub fn delete_issue(slot int, issue_key string) !ApiResponse {
	return api_call(slot, int(JiraActionId.delete_issue), '{"issueIdOrKey":"${issue_key}"}')
}

/// Add a comment to an issue.
pub fn add_comment(slot int, issue_key string, body string) !ApiResponse {
	return api_call(slot, int(JiraActionId.add_comment), '{"issueIdOrKey":"${issue_key}","body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"${body}"}]}]}}')
}

/// List all projects.
pub fn list_projects(slot int) !ApiResponse {
	return api_call(slot, int(JiraActionId.list_projects), '')
}

/// Get a single project by key or ID.
pub fn get_project(slot int, project_key string) !ApiResponse {
	return api_call(slot, int(JiraActionId.get_project), '{"projectIdOrKey":"${project_key}"}')
}

/// List boards (Agile API).
pub fn list_boards(slot int) !ApiResponse {
	return api_call(slot, int(JiraActionId.list_boards), '')
}

/// Get a single board by ID (Agile API).
pub fn get_board(slot int, board_id int) !ApiResponse {
	return api_call(slot, int(JiraActionId.get_board), '{"boardId":${board_id}}')
}

/// List sprints for a board (Agile API).
pub fn list_sprints(slot int, board_id int) !ApiResponse {
	return api_call(slot, int(JiraActionId.list_sprints), '{"boardId":${board_id}}')
}

/// Get a single sprint by ID (Agile API).
pub fn get_sprint(slot int, sprint_id int) !ApiResponse {
	return api_call(slot, int(JiraActionId.get_sprint), '{"sprintId":${sprint_id}}')
}

/// Transition an issue to a new status.
pub fn transition_issue(slot int, issue_key string, transition_id string) !ApiResponse {
	return api_call(slot, int(JiraActionId.transition_issue), '{"issueIdOrKey":"${issue_key}","transition":{"id":"${transition_id}"}}')
}

/// Assign an issue to a user.
pub fn assign_issue(slot int, issue_key string, account_id string) !ApiResponse {
	return api_call(slot, int(JiraActionId.assign_issue), '{"issueIdOrKey":"${issue_key}","accountId":"${account_id}"}')
}

/// List all custom and system fields.
pub fn list_fields(slot int) !ApiResponse {
	return api_call(slot, int(JiraActionId.list_fields), '')
}

/// Get a user by account ID.
pub fn get_user(slot int, account_id string) !ApiResponse {
	return api_call(slot, int(JiraActionId.get_user), '{"accountId":"${account_id}"}')
}

// ---------------------------------------------------------------------------
// Adapter functions — metrics and rate limits (for PanLL panels)
// ---------------------------------------------------------------------------

/// Get rate-limit status for a session.
pub fn rate_limit_status(slot int) RateLimitStatus {
	count := C.jira_mcp_rate_count(slot)
	return RateLimitStatus{
		slot: slot
		count: if count >= 0 { count } else { 0 }
		budget: 100
	}
}

/// Get full session metrics (state, instance, sprint progress, rate limits).
pub fn session_metrics(slot int) SessionMetrics {
	st := C.jira_mcp_session_state(slot)

	mut inst_buf := []u8{len: 256}
	mut inst_len := 0
	C.jira_mcp_instance(slot, inst_buf.data, 256, &inst_len)
	instance := if inst_len > 0 { inst_buf[..inst_len].bytestr() } else { '' }

	actions := C.jira_mcp_actions_performed(slot)
	sprint := C.jira_mcp_sprint_progress(slot)
	rate := C.jira_mcp_rate_count(slot)

	return SessionMetrics{
		slot: slot
		state: state_label(st)
		instance: instance
		actions_performed: if actions >= 0 { actions } else { 0 }
		sprint_progress: if sprint >= 0 { sprint } else { 0 }
		rate_count: if rate >= 0 { rate } else { 0 }
		rate_budget: 100
	}
}

/// Reset all sessions (test/debug use only).
pub fn reset() {
	C.jira_mcp_reset()
}
