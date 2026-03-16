// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// github_api_mcp_adapter.v — V-lang REST/GraphQL adapter for GitHub API cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Provides typed endpoints for all 20 GitHub actions plus GraphQL passthrough.

module github_api_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lgithub_api_mcp

fn C.github_api_mcp_can_transition(from int, to int) int
fn C.github_api_mcp_session_open() int
fn C.github_api_mcp_session_close(slot_idx int) int
fn C.github_api_mcp_session_state(slot_idx int) int
fn C.github_api_mcp_authenticate(slot_idx int, token_ptr &u8, token_len int) int
fn C.github_api_mcp_logout(slot_idx int) int
fn C.github_api_mcp_rate_limit_remaining(slot_idx int) int
fn C.github_api_mcp_rate_limit_reset(slot_idx int) int
fn C.github_api_mcp_throttle(slot_idx int) int
fn C.github_api_mcp_resume(slot_idx int) int
fn C.github_api_mcp_signal_error(slot_idx int) int
fn C.github_api_mcp_reset_error(slot_idx int) int
fn C.github_api_mcp_request(slot_idx int, method_ptr &u8, method_len int, path_ptr &u8, path_len int, body_ptr &u8, body_len int, out_ptr &u8, out_cap int) int
fn C.github_api_mcp_graphql(slot_idx int, query_ptr &u8, query_len int, variables_ptr &u8, variables_len int, out_ptr &u8, out_cap int) int
fn C.github_api_mcp_valid_action(code int) int
fn C.github_api_mcp_is_mutation(code int) int
fn C.github_api_mcp_reset()

// ---------------------------------------------------------------------------
// Auth state (matches Idris2 ABI / Zig FFI exactly)
// ---------------------------------------------------------------------------

enum AuthState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
}

fn auth_state_label(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'rate_limited' }
		3 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// GitHub action codes (matches Idris2/Zig exactly)
// ---------------------------------------------------------------------------

enum GitHubAction {
	list_repos       = 0
	get_repo         = 1
	create_issue     = 2
	list_issues      = 3
	get_issue        = 4
	comment_issue    = 5
	create_pr        = 6
	list_prs         = 7
	get_pr           = 8
	merge_pr         = 9
	review_pr        = 10
	list_branches    = 11
	create_branch    = 12
	search_code      = 13
	search_issues    = 14
	list_actions     = 15
	get_release      = 16
	create_release   = 17
	get_file_contents = 18
	push_files       = 19
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct SessionResponse {
	slot  int
	state string
}

struct AuthResponse {
	slot    int
	state   string
	message string
}

struct RateLimitResponse {
	remaining int
	reset     int
	limited   bool
}

struct ApiResponse {
	slot    int
	status  string
	body    string
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

struct ActionInfo {
	code      int
	valid     bool
	mutation  bool
}

// ---------------------------------------------------------------------------
// Output buffer size for API responses (64 KiB, matching Zig FFI)
// ---------------------------------------------------------------------------

const out_buf_size = 65536

// ---------------------------------------------------------------------------
// Session management
// ---------------------------------------------------------------------------

/// Open a new session (starts Unauthenticated).
pub fn session_open() !SessionResponse {
	slot := C.github_api_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'unauthenticated'
	}
}

/// Close a session and zero-fill token material.
pub fn session_close(slot int) !string {
	result := C.github_api_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not valid or not active') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Get the current auth state of a session.
pub fn session_state(slot int) !SessionResponse {
	s := C.github_api_mcp_session_state(slot)
	if s < 0 {
		return error('slot ${slot} not valid')
	}
	return SessionResponse{ slot: slot, state: auth_state_label(s) }
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

/// Authenticate a session with a Bearer token from vault-mcp.
pub fn authenticate(slot int, token string) !AuthResponse {
	result := C.github_api_mcp_authenticate(slot, token.str, token.len)
	return match result {
		0 {
			AuthResponse{
				slot: slot
				state: 'authenticated'
				message: 'token accepted'
			}
		}
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition (must be unauthenticated)') }
		-3 { return error('token too long or empty') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Logout (Authenticated -> Unauthenticated), zeroing stored token.
pub fn logout(slot int) !AuthResponse {
	result := C.github_api_mcp_logout(slot)
	return match result {
		0 {
			AuthResponse{
				slot: slot
				state: 'unauthenticated'
				message: 'logged out'
			}
		}
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition (must be authenticated)') }
		else { return error('unknown error (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

/// Get current rate limit status for a session.
pub fn rate_limit(slot int) !RateLimitResponse {
	remaining := C.github_api_mcp_rate_limit_remaining(slot)
	if remaining < 0 {
		return error('slot ${slot} not valid')
	}
	reset := C.github_api_mcp_rate_limit_reset(slot)
	return RateLimitResponse{
		remaining: remaining
		reset: reset
		limited: remaining == 0
	}
}

/// Manually throttle a session (Authenticated -> RateLimited).
pub fn throttle(slot int) !string {
	result := C.github_api_mcp_throttle(slot)
	return match result {
		0 { 'slot ${slot} rate limited' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition (must be authenticated)') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Resume from rate-limited state after cooldown.
pub fn resume(slot int) !string {
	result := C.github_api_mcp_resume(slot)
	return match result {
		0 { 'slot ${slot} resumed' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition (must be rate_limited)') }
		else { return error('unknown error (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

/// Signal an error on a session (Authenticated -> Error).
pub fn signal_error(slot int) !string {
	result := C.github_api_mcp_signal_error(slot)
	return match result {
		0 { 'slot ${slot} error state' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition (must be authenticated)') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Reset an error state (Error -> Unauthenticated).
pub fn reset_error(slot int) !string {
	result := C.github_api_mcp_reset_error(slot)
	return match result {
		0 { 'slot ${slot} reset to unauthenticated' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition (must be in error state)') }
		else { return error('unknown error (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// REST API endpoints — all 20 GitHub actions
// ---------------------------------------------------------------------------

/// Internal: issue a REST request via FFI and return the response body.
fn rest_call(slot int, method string, path string, body string) !ApiResponse {
	mut buf := []u8{len: out_buf_size}
	body_ptr := if body.len > 0 { body.str } else { unsafe { nil } }
	body_len := if body.len > 0 { body.len } else { 0 }
	written := C.github_api_mcp_request(
		slot,
		method.str, method.len,
		path.str, path.len,
		body_ptr, body_len,
		buf.data, out_buf_size
	)
	if written < 0 {
		return match written {
			-1 { error('slot ${slot} not valid') }
			-2 { error('not authenticated') }
			-3 { error('rate limited') }
			-4 { error('response too large for buffer') }
			-5 { error('network/HTTP error') }
			else { error('unknown error (code ${written})') }
		}
	}
	return ApiResponse{
		slot: slot
		status: 'ok'
		body: buf[..written].bytestr()
	}
}

/// List repositories for a user or organisation.
pub fn list_repos(slot int, owner string) !ApiResponse {
	return rest_call(slot, 'GET', '/users/${owner}/repos', '')
}

/// Get a single repository by owner/name.
pub fn get_repo(slot int, owner string, name string) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${name}', '')
}

/// Create an issue on a repository.
pub fn create_issue(slot int, owner string, repo string, title string, body string) !ApiResponse {
	payload := '{"title":"${title}","body":"${body}"}'
	return rest_call(slot, 'POST', '/repos/${owner}/${repo}/issues', payload)
}

/// List issues for a repository.
pub fn list_issues(slot int, owner string, repo string) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${repo}/issues', '')
}

/// Get a single issue by number.
pub fn get_issue(slot int, owner string, repo string, number int) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${repo}/issues/${number}', '')
}

/// Comment on an issue.
pub fn comment_issue(slot int, owner string, repo string, number int, body string) !ApiResponse {
	payload := '{"body":"${body}"}'
	return rest_call(slot, 'POST', '/repos/${owner}/${repo}/issues/${number}/comments', payload)
}

/// Create a pull request.
pub fn create_pr(slot int, owner string, repo string, title string, head string, base string, body string) !ApiResponse {
	payload := '{"title":"${title}","head":"${head}","base":"${base}","body":"${body}"}'
	return rest_call(slot, 'POST', '/repos/${owner}/${repo}/pulls', payload)
}

/// List pull requests for a repository.
pub fn list_prs(slot int, owner string, repo string) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${repo}/pulls', '')
}

/// Get a single pull request by number.
pub fn get_pr(slot int, owner string, repo string, number int) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${repo}/pulls/${number}', '')
}

/// Merge a pull request.
pub fn merge_pr(slot int, owner string, repo string, number int) !ApiResponse {
	return rest_call(slot, 'PUT', '/repos/${owner}/${repo}/pulls/${number}/merge', '{}')
}

/// Create a review on a pull request.
pub fn review_pr(slot int, owner string, repo string, number int, event string, body string) !ApiResponse {
	payload := '{"event":"${event}","body":"${body}"}'
	return rest_call(slot, 'POST', '/repos/${owner}/${repo}/pulls/${number}/reviews', payload)
}

/// List branches for a repository.
pub fn list_branches(slot int, owner string, repo string) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${repo}/branches', '')
}

/// Create a branch (via git refs API).
pub fn create_branch(slot int, owner string, repo string, branch string, sha string) !ApiResponse {
	payload := '{"ref":"refs/heads/${branch}","sha":"${sha}"}'
	return rest_call(slot, 'POST', '/repos/${owner}/${repo}/git/refs', payload)
}

/// Search code across GitHub.
pub fn search_code(slot int, query string) !ApiResponse {
	return rest_call(slot, 'GET', '/search/code?q=${query}', '')
}

/// Search issues and pull requests across GitHub.
pub fn search_issues(slot int, query string) !ApiResponse {
	return rest_call(slot, 'GET', '/search/issues?q=${query}', '')
}

/// List workflow runs (GitHub Actions) for a repository.
pub fn list_actions(slot int, owner string, repo string) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${repo}/actions/runs', '')
}

/// Get a release by tag.
pub fn get_release(slot int, owner string, repo string, tag string) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${repo}/releases/tags/${tag}', '')
}

/// Create a release.
pub fn create_release(slot int, owner string, repo string, tag string, name string, body string) !ApiResponse {
	payload := '{"tag_name":"${tag}","name":"${name}","body":"${body}"}'
	return rest_call(slot, 'POST', '/repos/${owner}/${repo}/releases', payload)
}

/// Get file contents from a repository.
pub fn get_file_contents(slot int, owner string, repo string, path string) !ApiResponse {
	return rest_call(slot, 'GET', '/repos/${owner}/${repo}/contents/${path}', '')
}

/// Push files to a repository (create/update file via Contents API).
pub fn push_files(slot int, owner string, repo string, path string, content_b64 string, message string) !ApiResponse {
	payload := '{"message":"${message}","content":"${content_b64}"}'
	return rest_call(slot, 'PUT', '/repos/${owner}/${repo}/contents/${path}', payload)
}

// ---------------------------------------------------------------------------
// GraphQL passthrough
// ---------------------------------------------------------------------------

/// Execute an arbitrary GraphQL query against the GitHub API.
pub fn graphql_query(slot int, query string, variables string) !ApiResponse {
	mut buf := []u8{len: out_buf_size}
	vars_ptr := if variables.len > 0 { variables.str } else { unsafe { nil } }
	vars_len := if variables.len > 0 { variables.len } else { 0 }
	written := C.github_api_mcp_graphql(
		slot,
		query.str, query.len,
		vars_ptr, vars_len,
		buf.data, out_buf_size
	)
	if written < 0 {
		return match written {
			-1 { error('slot ${slot} not valid') }
			-2 { error('not authenticated') }
			-3 { error('rate limited') }
			-4 { error('response too large for buffer') }
			-5 { error('network/HTTP error') }
			else { error('unknown error (code ${written})') }
		}
	}
	return ApiResponse{
		slot: slot
		status: 'ok'
		body: buf[..written].bytestr()
	}
}

// ---------------------------------------------------------------------------
// Action validation helpers
// ---------------------------------------------------------------------------

/// Check if a transition between two states is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.github_api_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Get information about a GitHub action by code.
pub fn action_info(code int) ActionInfo {
	valid := C.github_api_mcp_valid_action(code) == 1
	mutation_code := C.github_api_mcp_is_mutation(code)
	return ActionInfo{
		code: code
		valid: valid
		mutation: mutation_code == 1
	}
}

/// Reset all sessions (test/debug only).
pub fn reset() {
	C.github_api_mcp_reset()
}
