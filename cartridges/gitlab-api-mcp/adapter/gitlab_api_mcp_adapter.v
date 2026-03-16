// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gitlab_api_mcp_adapter.v — V-lang REST/GraphQL adapter for gitlab-api-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Wraps all 20 GitLab actions (REST API v4 + GraphQL), supporting both
// gitlab.com and self-hosted instances. Authentication via Private-Token
// header (token sourced from vault-mcp).

module gitlab_api_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lgitlab_api_mcp

fn C.gitlab_api_mcp_can_transition(from int, to int) int
fn C.gitlab_api_mcp_session_open() int
fn C.gitlab_api_mcp_session_close(slot_idx int) int
fn C.gitlab_api_mcp_session_state(slot_idx int) int
fn C.gitlab_api_mcp_authenticate(slot_idx int, token &u8, token_len int, base_url &u8, url_len int) int
fn C.gitlab_api_mcp_request(slot_idx int, method int, path &u8, path_len int, body &u8, body_len int, out_buf &u8, out_cap int, out_len &int) int
fn C.gitlab_api_mcp_graphql(slot_idx int, query &u8, query_len int, variables &u8, variables_len int, out_buf &u8, out_cap int, out_len &int) int
fn C.gitlab_api_mcp_setup_mirror(slot_idx int, project_id int, target_url &u8, url_len int, out_buf &u8, out_cap int, out_len &int) int
fn C.gitlab_api_mcp_hit_rate_limit(slot_idx int) int
fn C.gitlab_api_mcp_resume_from_rate_limit(slot_idx int) int
fn C.gitlab_api_mcp_signal_error(slot_idx int) int
fn C.gitlab_api_mcp_reset_error(slot_idx int) int
fn C.gitlab_api_mcp_logout(slot_idx int) int
fn C.gitlab_api_mcp_rate_limit_remaining(slot_idx int) int
fn C.gitlab_api_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

/// Authentication/session state for GitLab API operations.
enum SessionState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
}

/// HTTP methods for REST API calls.
enum HttpMethod {
	get    = 0
	post   = 1
	put    = 2
	delete = 3
}

/// All 20 GitLab actions exposed by this cartridge.
enum GitLabAction {
	list_projects    = 0
	get_project      = 1
	create_issue     = 2
	list_issues      = 3
	get_issue        = 4
	comment_issue    = 5
	create_mr        = 6
	list_mrs         = 7
	get_mr           = 8
	merge_mr         = 9
	list_branches    = 10
	create_branch    = 11
	search_code      = 12
	list_pipelines   = 13
	get_pipeline     = 14
	trigger_pipeline = 15
	list_releases    = 16
	create_release   = 17
	push_mirror      = 18
	get_file_contents = 19
}

/// Convert session state integer to human-readable label.
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

/// Response from opening a session.
struct SessionResponse {
	slot  int
	state string
}

/// Response from querying session state.
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

/// Response from a GitLab API call.
struct ApiResponse {
	slot    int
	action  string
	body    string
	success bool
}

/// Rate-limit information for a session.
struct RateLimitInfo {
	slot      int
	remaining int
	state     string
}

/// Response from push mirror setup.
struct MirrorResponse {
	slot       int
	project_id int
	target_url string
	body       string
	success    bool
}

// ---------------------------------------------------------------------------
// Session management
// ---------------------------------------------------------------------------

/// Open a new session in Unauthenticated state.
pub fn session_open() !SessionResponse {
	slot := C.gitlab_api_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'unauthenticated'
	}
}

/// Close a session. Slot must be Authenticated or Unauthenticated.
pub fn session_close(slot int) !string {
	result := C.gitlab_api_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition — must be authenticated or unauthenticated to close') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Get the current state of a session.
pub fn session_state(slot int) StateResponse {
	s := C.gitlab_api_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

/// Check if a state transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.gitlab_api_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Get rate-limit info for a session.
pub fn rate_limit_info(slot int) RateLimitInfo {
	remaining := C.gitlab_api_mcp_rate_limit_remaining(slot)
	s := C.gitlab_api_mcp_session_state(slot)
	return RateLimitInfo{
		slot: slot
		remaining: remaining
		state: state_label(s)
	}
}

/// Reset all sessions (test/debug use only).
pub fn reset() {
	C.gitlab_api_mcp_reset()
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

/// Authenticate with a GitLab Private-Token. Optionally specify a self-hosted
/// instance base URL (pass empty string for default https://gitlab.com).
pub fn authenticate(slot int, token string, base_url string) !string {
	url_ptr := if base_url.len > 0 { base_url.str } else { unsafe { nil } }
	url_len := if base_url.len > 0 { base_url.len } else { 0 }
	result := C.gitlab_api_mcp_authenticate(slot, token.str, token.len, url_ptr, url_len)
	return match result {
		0 { 'authenticated slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition — must be unauthenticated to authenticate') }
		-3 { return error('token invalid or too long') }
		-4 { return error('base URL too long') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Logout from a session (Authenticated -> Unauthenticated). Zeroes the token.
pub fn logout(slot int) !string {
	result := C.gitlab_api_mcp_logout(slot)
	return match result {
		0 { 'logged out slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition — must be authenticated to logout') }
		else { return error('unknown error (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Execute a REST API request via the FFI layer.
fn do_request(slot int, method HttpMethod, path string, body string) !string {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	body_ptr := if body.len > 0 { body.str } else { unsafe { nil } }
	body_len := if body.len > 0 { body.len } else { 0 }
	result := C.gitlab_api_mcp_request(slot, int(method), path.str, path.len,
		body_ptr, body_len, buf.data, buf.len, &out_len)
	if result < 0 {
		return match result {
			-1 { error('slot not active') }
			-2 { error('not authenticated') }
			-3 { error('rate limited') }
			-4 { error('request error') }
			-5 { error('response buffer too small') }
			else { error('unknown error (code ${result})') }
		}
	}
	return buf[..out_len].bytestr()
}

/// Execute a GraphQL query via the FFI layer.
fn do_graphql(slot int, query string, variables string) !string {
	mut buf := []u8{len: 8192}
	mut out_len := 0
	vars_ptr := if variables.len > 0 { variables.str } else { unsafe { nil } }
	vars_len := if variables.len > 0 { variables.len } else { 0 }
	result := C.gitlab_api_mcp_graphql(slot, query.str, query.len,
		vars_ptr, vars_len, buf.data, buf.len, &out_len)
	if result < 0 {
		return match result {
			-1 { error('slot not active') }
			-2 { error('not authenticated') }
			-4 { error('query error') }
			-5 { error('response buffer too small') }
			else { error('unknown error (code ${result})') }
		}
	}
	return buf[..out_len].bytestr()
}

// ---------------------------------------------------------------------------
// GitLab REST API actions (all 20)
// ---------------------------------------------------------------------------

/// List projects visible to the authenticated user.
/// GET /projects
pub fn list_projects(slot int, query_params string) !ApiResponse {
	path := if query_params.len > 0 { '/projects?${query_params}' } else { '/projects' }
	body := do_request(slot, .get, path, '') !
	return ApiResponse{ slot: slot, action: 'list_projects', body: body, success: true }
}

/// Get a single project by ID or URL-encoded path.
/// GET /projects/:id
pub fn get_project(slot int, project_id string) !ApiResponse {
	body := do_request(slot, .get, '/projects/${project_id}', '') !
	return ApiResponse{ slot: slot, action: 'get_project', body: body, success: true }
}

/// Create an issue in a project.
/// POST /projects/:id/issues
pub fn create_issue(slot int, project_id string, issue_json string) !ApiResponse {
	body := do_request(slot, .post, '/projects/${project_id}/issues', issue_json) !
	return ApiResponse{ slot: slot, action: 'create_issue', body: body, success: true }
}

/// List issues for a project.
/// GET /projects/:id/issues
pub fn list_issues(slot int, project_id string, query_params string) !ApiResponse {
	path := '/projects/${project_id}/issues'
	full_path := if query_params.len > 0 { '${path}?${query_params}' } else { path }
	body := do_request(slot, .get, full_path, '') !
	return ApiResponse{ slot: slot, action: 'list_issues', body: body, success: true }
}

/// Get a single issue.
/// GET /projects/:id/issues/:issue_iid
pub fn get_issue(slot int, project_id string, issue_iid string) !ApiResponse {
	body := do_request(slot, .get, '/projects/${project_id}/issues/${issue_iid}', '') !
	return ApiResponse{ slot: slot, action: 'get_issue', body: body, success: true }
}

/// Add a comment (note) to an issue.
/// POST /projects/:id/issues/:issue_iid/notes
pub fn comment_issue(slot int, project_id string, issue_iid string, note_json string) !ApiResponse {
	body := do_request(slot, .post, '/projects/${project_id}/issues/${issue_iid}/notes', note_json) !
	return ApiResponse{ slot: slot, action: 'comment_issue', body: body, success: true }
}

/// Create a merge request.
/// POST /projects/:id/merge_requests
pub fn create_mr(slot int, project_id string, mr_json string) !ApiResponse {
	body := do_request(slot, .post, '/projects/${project_id}/merge_requests', mr_json) !
	return ApiResponse{ slot: slot, action: 'create_mr', body: body, success: true }
}

/// List merge requests for a project.
/// GET /projects/:id/merge_requests
pub fn list_mrs(slot int, project_id string, query_params string) !ApiResponse {
	path := '/projects/${project_id}/merge_requests'
	full_path := if query_params.len > 0 { '${path}?${query_params}' } else { path }
	body := do_request(slot, .get, full_path, '') !
	return ApiResponse{ slot: slot, action: 'list_mrs', body: body, success: true }
}

/// Get a single merge request.
/// GET /projects/:id/merge_requests/:mr_iid
pub fn get_mr(slot int, project_id string, mr_iid string) !ApiResponse {
	body := do_request(slot, .get, '/projects/${project_id}/merge_requests/${mr_iid}', '') !
	return ApiResponse{ slot: slot, action: 'get_mr', body: body, success: true }
}

/// Accept (merge) a merge request.
/// PUT /projects/:id/merge_requests/:mr_iid/merge
pub fn merge_mr(slot int, project_id string, mr_iid string, merge_json string) !ApiResponse {
	body := do_request(slot, .put, '/projects/${project_id}/merge_requests/${mr_iid}/merge', merge_json) !
	return ApiResponse{ slot: slot, action: 'merge_mr', body: body, success: true }
}

/// List branches for a project.
/// GET /projects/:id/repository/branches
pub fn list_branches(slot int, project_id string, query_params string) !ApiResponse {
	path := '/projects/${project_id}/repository/branches'
	full_path := if query_params.len > 0 { '${path}?${query_params}' } else { path }
	body := do_request(slot, .get, full_path, '') !
	return ApiResponse{ slot: slot, action: 'list_branches', body: body, success: true }
}

/// Create a branch.
/// POST /projects/:id/repository/branches
pub fn create_branch(slot int, project_id string, branch_json string) !ApiResponse {
	body := do_request(slot, .post, '/projects/${project_id}/repository/branches', branch_json) !
	return ApiResponse{ slot: slot, action: 'create_branch', body: body, success: true }
}

/// Search code across projects.
/// GET /projects/:id/search?scope=blobs&search=<query>
pub fn search_code(slot int, project_id string, search_query string) !ApiResponse {
	body := do_request(slot, .get, '/projects/${project_id}/search?scope=blobs&search=${search_query}', '') !
	return ApiResponse{ slot: slot, action: 'search_code', body: body, success: true }
}

/// List pipelines for a project.
/// GET /projects/:id/pipelines
pub fn list_pipelines(slot int, project_id string, query_params string) !ApiResponse {
	path := '/projects/${project_id}/pipelines'
	full_path := if query_params.len > 0 { '${path}?${query_params}' } else { path }
	body := do_request(slot, .get, full_path, '') !
	return ApiResponse{ slot: slot, action: 'list_pipelines', body: body, success: true }
}

/// Get a single pipeline.
/// GET /projects/:id/pipelines/:pipeline_id
pub fn get_pipeline(slot int, project_id string, pipeline_id string) !ApiResponse {
	body := do_request(slot, .get, '/projects/${project_id}/pipelines/${pipeline_id}', '') !
	return ApiResponse{ slot: slot, action: 'get_pipeline', body: body, success: true }
}

/// Trigger a pipeline.
/// POST /projects/:id/pipeline
pub fn trigger_pipeline(slot int, project_id string, trigger_json string) !ApiResponse {
	body := do_request(slot, .post, '/projects/${project_id}/pipeline', trigger_json) !
	return ApiResponse{ slot: slot, action: 'trigger_pipeline', body: body, success: true }
}

/// List releases for a project.
/// GET /projects/:id/releases
pub fn list_releases(slot int, project_id string, query_params string) !ApiResponse {
	path := '/projects/${project_id}/releases'
	full_path := if query_params.len > 0 { '${path}?${query_params}' } else { path }
	body := do_request(slot, .get, full_path, '') !
	return ApiResponse{ slot: slot, action: 'list_releases', body: body, success: true }
}

/// Create a release.
/// POST /projects/:id/releases
pub fn create_release(slot int, project_id string, release_json string) !ApiResponse {
	body := do_request(slot, .post, '/projects/${project_id}/releases', release_json) !
	return ApiResponse{ slot: slot, action: 'create_release', body: body, success: true }
}

/// Set up a push mirror from a GitLab project to a remote repository.
/// POST /projects/:id/remote_mirrors
pub fn push_mirror(slot int, project_id int, target_url string) !MirrorResponse {
	mut buf := []u8{len: 4096}
	mut out_len := 0
	result := C.gitlab_api_mcp_setup_mirror(slot, project_id, target_url.str,
		target_url.len, buf.data, buf.len, &out_len)
	if result < 0 {
		return error('mirror setup failed (code ${result})')
	}
	return MirrorResponse{
		slot: slot
		project_id: project_id
		target_url: target_url
		body: buf[..out_len].bytestr()
		success: true
	}
}

/// Get file contents from a repository.
/// GET /projects/:id/repository/files/:file_path/raw
pub fn get_file_contents(slot int, project_id string, file_path string, ref string) !ApiResponse {
	ref_param := if ref.len > 0 { '?ref=${ref}' } else { '?ref=main' }
	body := do_request(slot, .get, '/projects/${project_id}/repository/files/${file_path}/raw${ref_param}', '') !
	return ApiResponse{ slot: slot, action: 'get_file_contents', body: body, success: true }
}

// ---------------------------------------------------------------------------
// GraphQL adapter
// ---------------------------------------------------------------------------

/// Execute an arbitrary GraphQL query against the GitLab instance.
pub fn graphql_query(slot int, query string, variables string) !ApiResponse {
	body := do_graphql(slot, query, variables) !
	return ApiResponse{ slot: slot, action: 'graphql', body: body, success: true }
}
