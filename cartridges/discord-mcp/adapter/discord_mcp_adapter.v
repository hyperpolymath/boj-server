// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// discord_mcp_adapter.v — V-lang adapter for discord-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Covers all 16 Discord REST API v10 actions: messages, channels, guilds,
// members, reactions, threads, search, status, and file uploads.
// Auth: Bot token with "Bot" prefix in Authorization header.
// Rate limiting: bucket-based per-route (Discord X-RateLimit-Bucket).

module discord_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -ldiscord_mcp

fn C.discord_mcp_can_transition(from int, to int) int
fn C.discord_mcp_session_open() int
fn C.discord_mcp_session_close(slot_idx int) int
fn C.discord_mcp_session_state(slot_idx int) int
fn C.discord_mcp_authenticate(slot_idx int) int
fn C.discord_mcp_connect(slot_idx int) int
fn C.discord_mcp_rate_limit(slot_idx int) int
fn C.discord_mcp_signal_error(slot_idx int) int
fn C.discord_mcp_recover(slot_idx int) int
fn C.discord_mcp_validate_token(ptr &u8, len usize) int
fn C.discord_mcp_is_valid_action(action int) int
fn C.discord_mcp_action_count() int
fn C.discord_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 ABI exactly)
// ---------------------------------------------------------------------------

// Connection state: Disconnected(0) | Authenticating(1) | Connected(2) |
// RateLimited(3) | Error(4)
enum ConnState {
	disconnected   = 0
	authenticating = 1
	connected      = 2
	rate_limited   = 3
	err            = 4
}

// All 16 Discord actions.
enum DiscordAction {
	send_message    = 0
	edit_message    = 1
	delete_message  = 2
	list_channels   = 3
	get_channel     = 4
	list_guilds     = 5
	get_guild       = 6
	list_members    = 7
	get_member      = 8
	add_reaction    = 9
	remove_reaction = 10
	create_thread   = 11
	list_threads    = 12
	search_messages = 13
	set_status      = 14
	upload_file     = 15
}

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'authenticating' }
		2 { 'connected' }
		3 { 'rate_limited' }
		4 { 'error' }
		else { 'unknown' }
	}
}

fn action_label(a int) string {
	return match a {
		0 { 'send_message' }
		1 { 'edit_message' }
		2 { 'delete_message' }
		3 { 'list_channels' }
		4 { 'get_channel' }
		5 { 'list_guilds' }
		6 { 'get_guild' }
		7 { 'list_members' }
		8 { 'get_member' }
		9 { 'add_reaction' }
		10 { 'remove_reaction' }
		11 { 'create_thread' }
		12 { 'list_threads' }
		13 { 'search_messages' }
		14 { 'set_status' }
		15 { 'upload_file' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct SessionResponse {
	slot  int
	state string
}

struct StateResponse {
	slot  int
	state string
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

struct ActionResponse {
	action string
	valid  bool
}

// ---------------------------------------------------------------------------
// Base URL
// ---------------------------------------------------------------------------

const base_url = 'https://discord.com/api/v10/'

// ---------------------------------------------------------------------------
// Adapter functions: session management
// ---------------------------------------------------------------------------

// Open a new session in Disconnected state.
pub fn session_open() !SessionResponse {
	slot := C.discord_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'disconnected'
	}
}

// Close a session (must be Connected or Error).
pub fn session_close(slot int) !string {
	result := C.discord_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

// Get current session state.
pub fn session_state(slot int) StateResponse {
	s := C.discord_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

// ---------------------------------------------------------------------------
// Adapter functions: state transitions
// ---------------------------------------------------------------------------

// Begin authentication (Disconnected -> Authenticating).
pub fn authenticate(slot int) !string {
	result := C.discord_mcp_authenticate(slot)
	return match result {
		0 { 'authenticating on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Complete authentication (Authenticating -> Connected).
pub fn connect(slot int) !string {
	result := C.discord_mcp_connect(slot)
	return match result {
		0 { 'connected on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Enter rate-limited state (Connected -> RateLimited).
pub fn rate_limit(slot int) !string {
	result := C.discord_mcp_rate_limit(slot)
	return match result {
		0 { 'rate limited on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Signal an error on a session.
pub fn signal_error(slot int) !string {
	result := C.discord_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Recover from error (Error -> Disconnected).
pub fn recover(slot int) !string {
	result := C.discord_mcp_recover(slot)
	return match result {
		0 { 'recovered on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// ---------------------------------------------------------------------------
// Adapter functions: actions and validation
// ---------------------------------------------------------------------------

// Validate a Discord bot token.
pub fn validate_token(token string) bool {
	return C.discord_mcp_validate_token(token.str, token.len) == 1
}

// Check if a transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.discord_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

// Check if an action code is valid.
pub fn is_valid_action(action int) ActionResponse {
	valid := C.discord_mcp_is_valid_action(action) == 1
	return ActionResponse{ action: action_label(action), valid: valid }
}

// Get total action count.
pub fn action_count() int {
	return C.discord_mcp_action_count()
}

// Reset all sessions (test/debug only).
pub fn reset() {
	C.discord_mcp_reset()
}
