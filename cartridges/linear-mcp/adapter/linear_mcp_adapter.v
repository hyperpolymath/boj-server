// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// linear_mcp_adapter.v — V-lang REST adapter for the Linear GraphQL API cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes REST endpoints for all 16 Linear actions, connection management,
// rate-limit inspection, and session metrics.

module linear_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -llinear_mcp

fn C.linear_mcp_can_transition(from int, to int) int
fn C.linear_mcp_authenticate(token &u8) int
fn C.linear_mcp_disconnect(slot_idx int) int
fn C.linear_mcp_session_state(slot_idx int) int
fn C.linear_mcp_rate_count(slot_idx int) int
fn C.linear_mcp_actions_performed(slot_idx int) int
fn C.linear_mcp_issue_count(slot_idx int) int
fn C.linear_mcp_rate_recover(slot_idx int) int
fn C.linear_mcp_graphql_call(slot_idx int, action_id int, params &u8, out_buf &u8, out_cap int, out_len &int) int
fn C.linear_mcp_reset()

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
// Linear action IDs (mirrors Idris2 LinearAction / Zig LinearAction)
// ---------------------------------------------------------------------------

enum LinearActionId {
	list_issues          = 0
	get_issue            = 1
	create_issue         = 2
	update_issue         = 3
	delete_issue         = 4
	list_projects        = 5
	get_project          = 6
	list_teams           = 7
	list_cycles          = 8
	create_comment       = 9
	search_issues        = 10
	list_labels          = 11
	assign_issue         = 12
	set_priority         = 13
	move_to_project      = 14
	list_workflow_states = 15
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
	slot  int
	state string
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

/// Response from Linear API operations (generic JSON envelope).
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
	actions_performed int
	issue_count       int
	rate_count        int
	rate_budget       int
}

// ---------------------------------------------------------------------------
// Adapter functions — connection lifecycle
// ---------------------------------------------------------------------------

/// Authenticate with Linear using a Bearer API key.
/// The API key should be retrieved from vault-mcp before calling.
pub fn authenticate(token string) !ConnectResponse {
	slot := C.linear_mcp_authenticate(token.str)
	if slot == -1 {
		return error('no session slots available')
	}
	if slot == -3 {
		return error('empty token')
	}
	if slot == -4 {
		return error('token too short (Linear API keys are typically 40+ characters)')
	}
	if slot < 0 {
		return error('authentication failed (code ${slot})')
	}
	return ConnectResponse{
		slot: slot
		state: 'authenticated'
	}
}

/// Disconnect a session gracefully.
pub fn disconnect(slot int) !string {
	result := C.linear_mcp_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for disconnect') }
		else { return error('disconnect failed (code ${result})') }
	}
}

/// Get the current connection state of a session.
pub fn session_state(slot int) StateResponse {
	s := C.linear_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

/// Check if a state transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.linear_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Recover from a rate-limited state.
pub fn rate_recover(slot int) !string {
	result := C.linear_mcp_rate_recover(slot)
	return match result {
		0 { 'recovered slot ${slot} to authenticated' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('not in rate_limited state') }
		else { return error('recovery failed (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Adapter functions — Linear API actions (all 16)
// ---------------------------------------------------------------------------

/// Generic GraphQL call by action ID. Covers all 16 actions.
pub fn graphql_call(slot int, action_id int, params string) !ApiResponse {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	params_ptr := if params.len > 0 { params.str } else { unsafe { nil } }
	result := C.linear_mcp_graphql_call(slot, action_id, params_ptr, buf.data, 8192, &out_len)
	if result == -6 {
		return error('unknown action id ${action_id}')
	}
	if result == -5 {
		return error('rate limited')
	}
	if result < 0 {
		return error('graphql_call failed (code ${result})')
	}

	action_name := match action_id {
		0 { 'list_issues' }
		1 { 'get_issue' }
		2 { 'create_issue' }
		3 { 'update_issue' }
		4 { 'delete_issue' }
		5 { 'list_projects' }
		6 { 'get_project' }
		7 { 'list_teams' }
		8 { 'list_cycles' }
		9 { 'create_comment' }
		10 { 'search_issues' }
		11 { 'list_labels' }
		12 { 'assign_issue' }
		13 { 'set_priority' }
		14 { 'move_to_project' }
		15 { 'list_workflow_states' }
		else { 'unknown' }
	}
	return ApiResponse{ slot: slot, action: action_name, body: buf[..out_len].bytestr() }
}

// ---------------------------------------------------------------------------
// Convenience wrappers for each action (delegate to graphql_call)
// ---------------------------------------------------------------------------

/// List issues with optional filter parameters.
pub fn list_issues(slot int, params string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.list_issues), params)
}

/// Get a single issue by ID.
pub fn get_issue(slot int, issue_id string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.get_issue), '{"id":"${issue_id}"}')
}

/// Create a new issue.
pub fn create_issue(slot int, team_id string, title string, description string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.create_issue), '{"teamId":"${team_id}","title":"${title}","description":"${description}"}')
}

/// Update an existing issue.
pub fn update_issue(slot int, issue_id string, params string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.update_issue), '{"id":"${issue_id}",${params}}')
}

/// Delete an issue.
pub fn delete_issue(slot int, issue_id string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.delete_issue), '{"id":"${issue_id}"}')
}

/// List projects.
pub fn list_projects(slot int) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.list_projects), '')
}

/// Get a single project by ID.
pub fn get_project(slot int, project_id string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.get_project), '{"id":"${project_id}"}')
}

/// List teams.
pub fn list_teams(slot int) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.list_teams), '')
}

/// List cycles.
pub fn list_cycles(slot int) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.list_cycles), '')
}

/// Create a comment on an issue.
pub fn create_comment(slot int, issue_id string, body string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.create_comment), '{"issueId":"${issue_id}","body":"${body}"}')
}

/// Search issues by query string.
pub fn search_issues(slot int, query string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.search_issues), '{"query":"${query}"}')
}

/// List issue labels.
pub fn list_labels(slot int) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.list_labels), '')
}

/// Assign an issue to a user.
pub fn assign_issue(slot int, issue_id string, assignee_id string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.assign_issue), '{"id":"${issue_id}","assigneeId":"${assignee_id}"}')
}

/// Set issue priority (0=none, 1=urgent, 2=high, 3=medium, 4=low).
pub fn set_priority(slot int, issue_id string, priority int) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.set_priority), '{"id":"${issue_id}","priority":${priority}}')
}

/// Move an issue to a different project.
pub fn move_to_project(slot int, issue_id string, project_id string) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.move_to_project), '{"id":"${issue_id}","projectId":"${project_id}"}')
}

/// List workflow states.
pub fn list_workflow_states(slot int) !ApiResponse {
	return graphql_call(slot, int(LinearActionId.list_workflow_states), '')
}

// ---------------------------------------------------------------------------
// Adapter functions — metrics and rate limits (for PanLL panels)
// ---------------------------------------------------------------------------

/// Get rate-limit status for a session.
pub fn rate_limit_status(slot int) RateLimitStatus {
	count := C.linear_mcp_rate_count(slot)
	return RateLimitStatus{
		slot: slot
		count: if count >= 0 { count } else { 0 }
		budget: 50
	}
}

/// Get full session metrics (state, actions, issues, rate limits).
pub fn session_metrics(slot int) SessionMetrics {
	st := C.linear_mcp_session_state(slot)
	actions := C.linear_mcp_actions_performed(slot)
	issues := C.linear_mcp_issue_count(slot)
	rate := C.linear_mcp_rate_count(slot)

	return SessionMetrics{
		slot: slot
		state: state_label(st)
		actions_performed: if actions >= 0 { actions } else { 0 }
		issue_count: if issues >= 0 { issues } else { 0 }
		rate_count: if rate >= 0 { rate } else { 0 }
		rate_budget: 50
	}
}

/// Reset all sessions (test/debug use only).
pub fn reset() {
	C.linear_mcp_reset()
}
