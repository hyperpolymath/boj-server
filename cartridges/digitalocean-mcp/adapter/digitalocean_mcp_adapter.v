// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// digitalocean_mcp_adapter.v — V-lang REST adapter for DigitalOcean MCP cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// DigitalOcean API: https://api.digitalocean.com/v2/
// Auth: Bearer token (personal access token).
// Rate limit: 5000 requests/hour.

module digitalocean_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -ldigitalocean_mcp

fn C.digitalocean_mcp_can_transition(from int, to int) int
fn C.digitalocean_mcp_authenticate(token_ptr &u8, token_len int) int
fn C.digitalocean_mcp_session_close(slot_idx int) int
fn C.digitalocean_mcp_session_state(slot_idx int) int
fn C.digitalocean_mcp_execute_action(slot_idx int, action_code int) int
fn C.digitalocean_mcp_rate_limit_remaining(slot_idx int) int
fn C.digitalocean_mcp_rate_limit_reset(slot_idx int) int
fn C.digitalocean_mcp_signal_error(slot_idx int) int
fn C.digitalocean_mcp_recover(slot_idx int) int
fn C.digitalocean_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 ABI)
// ---------------------------------------------------------------------------

enum AuthState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
}

enum DigitaloceanAction {
	list_droplets   = 0
	get_droplet     = 1
	create_droplet  = 2
	delete_droplet  = 3
	power_on        = 4
	power_off       = 5
	reboot          = 6
	list_volumes    = 7
	create_volume   = 8
	list_domains    = 9
	create_domain   = 10
	list_ssh_keys   = 11
	list_snapshots  = 12
	create_snapshot = 13
	list_databases  = 14
	get_account     = 15
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
	slot            int
	action          int
	rate_remaining  int
}

struct TransitionResponse {
	from    int
	to      int
	valid   bool
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

/// Authenticate with a DigitalOcean personal access token.
/// Returns slot index and state on success.
pub fn authenticate(token string) !AuthResponse {
	slot := C.digitalocean_mcp_authenticate(token.str, token.len)
	if slot == -2 {
		return error('invalid or empty bearer token')
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
	result := C.digitalocean_mcp_session_close(slot)
	return match result {
		0 { 'logged out slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for logout') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Get current auth state for a session.
pub fn session_state(slot int) StateResponse {
	s := C.digitalocean_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

/// Execute a DigitalOcean API action.
pub fn execute_action(slot int, action int) !ActionResponse {
	result := C.digitalocean_mcp_execute_action(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not authenticated')
	}
	if result == -3 {
		return error('rate limited (5000 req/hour exceeded)')
	}
	if result == -4 {
		return error('invalid action code')
	}
	remaining := C.digitalocean_mcp_rate_limit_remaining(slot)
	return ActionResponse{
		slot: slot
		action: action
		rate_remaining: remaining
	}
}

/// Get remaining rate limit for a session.
pub fn rate_limit_remaining(slot int) int {
	return C.digitalocean_mcp_rate_limit_remaining(slot)
}

/// Check if a transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.digitalocean_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Signal an error on a session.
pub fn signal_error(slot int) !string {
	result := C.digitalocean_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for error') }
		else { return error('unknown error') }
	}
}

/// Recover a session from error state.
pub fn recover(slot int) !string {
	result := C.digitalocean_mcp_recover(slot)
	return match result {
		0 { 'recovered slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('slot not in error state') }
		else { return error('unknown error') }
	}
}

/// Reset all sessions (test/debug).
pub fn reset() {
	C.digitalocean_mcp_reset()
}
