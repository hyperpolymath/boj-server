// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// docker_hub_mcp_adapter.v — V-lang REST adapter for Docker Hub MCP cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Docker Hub API: https://hub.docker.com/v2/
// Auth: Two-phase — POST /v2/users/login with username/password -> JWT bearer token.
// Pull rate limit: 100 (anonymous) / 200 (authenticated) per 6 hours.

module docker_hub_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -ldocker_hub_mcp

fn C.docker_hub_mcp_can_transition(from int, to int) int
fn C.docker_hub_mcp_authenticate(jwt_ptr &u8, jwt_len int) int
fn C.docker_hub_mcp_session_close(slot_idx int) int
fn C.docker_hub_mcp_session_state(slot_idx int) int
fn C.docker_hub_mcp_execute_action(slot_idx int, action_code int) int
fn C.docker_hub_mcp_pull_rate_remaining(slot_idx int) int
fn C.docker_hub_mcp_consume_pull(slot_idx int) int
fn C.docker_hub_mcp_pull_rate_reset(slot_idx int) int
fn C.docker_hub_mcp_signal_error(slot_idx int) int
fn C.docker_hub_mcp_recover(slot_idx int) int
fn C.docker_hub_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 ABI)
// ---------------------------------------------------------------------------

enum AuthState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
}

enum DockerHubAction {
	search_images     = 0
	get_repository    = 1
	list_tags         = 2
	get_tag           = 3
	list_namespaces   = 4
	get_manifest      = 5
	delete_tag        = 6
	get_rate_limit    = 7
	list_orgs         = 8
	create_repository = 9
	delete_repository = 10
	get_dockerfile    = 11
	list_starred      = 12
	star_repository   = 13
	unstar_repository = 14
	get_user          = 15
}

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

struct AuthResponse {
	slot  int
	state string
}

struct StateResponse {
	slot  int
	state string
}

struct ActionResponse {
	slot             int
	action           int
	pulls_remaining  int
}

struct TransitionResponse {
	from    int
	to      int
	valid   bool
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

/// Authenticate with a Docker Hub JWT (from POST /v2/users/login).
/// Two-phase auth: caller obtains JWT first, then passes it here.
pub fn authenticate(jwt string) !AuthResponse {
	slot := C.docker_hub_mcp_authenticate(jwt.str, jwt.len)
	if slot == -2 {
		return error('invalid or empty JWT token')
	}
	if slot < 0 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
	}
}

/// Close/logout a session.
pub fn session_close(slot int) !string {
	result := C.docker_hub_mcp_session_close(slot)
	return match result {
		0 { 'logged out slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for logout') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Get current auth state for a session.
pub fn session_state(slot int) StateResponse {
	s := C.docker_hub_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

/// Execute a Docker Hub API action.
pub fn execute_action(slot int, action int) !ActionResponse {
	result := C.docker_hub_mcp_execute_action(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not authenticated')
	}
	if result == -3 {
		return error('rate limited (pull limit exceeded)')
	}
	if result == -4 {
		return error('invalid action code')
	}
	remaining := C.docker_hub_mcp_pull_rate_remaining(slot)
	return ActionResponse{
		slot: slot
		action: action
		pulls_remaining: remaining
	}
}

/// Get remaining pull rate limit for a session.
pub fn pull_rate_remaining(slot int) int {
	return C.docker_hub_mcp_pull_rate_remaining(slot)
}

/// Consume one pull from the rate limit counter.
pub fn consume_pull(slot int) !int {
	result := C.docker_hub_mcp_consume_pull(slot)
	if result == -1 {
		return error('slot not active')
	}
	if result == -3 {
		return error('pull rate limit exhausted')
	}
	return result
}

/// Check if a transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.docker_hub_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Signal an error on a session.
pub fn signal_error(slot int) !string {
	result := C.docker_hub_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for error') }
		else { return error('unknown error') }
	}
}

/// Recover a session from error state.
pub fn recover(slot int) !string {
	result := C.docker_hub_mcp_recover(slot)
	return match result {
		0 { 'recovered slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('slot not in error state') }
		else { return error('unknown error') }
	}
}

/// Reset all sessions (test/debug).
pub fn reset() {
	C.docker_hub_mcp_reset()
}
