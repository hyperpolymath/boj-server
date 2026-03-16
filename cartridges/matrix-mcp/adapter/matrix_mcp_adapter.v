// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// matrix_mcp_adapter.v — V-lang adapter for matrix-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Covers all 16 Matrix Client-Server API v3 actions: messages, events,
// rooms, membership, state, sync, search, media, profiles, and room creation.
// Auth: Bearer token against configurable homeserver URL.
// Idempotency: transaction ID generation for PUT requests.

module matrix_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lmatrix_mcp

fn C.matrix_mcp_can_transition(from int, to int) int
fn C.matrix_mcp_session_open() int
fn C.matrix_mcp_session_close(slot_idx int) int
fn C.matrix_mcp_session_state(slot_idx int) int
fn C.matrix_mcp_authenticate(slot_idx int) int
fn C.matrix_mcp_connect(slot_idx int) int
fn C.matrix_mcp_begin_sync(slot_idx int) int
fn C.matrix_mcp_end_sync(slot_idx int) int
fn C.matrix_mcp_signal_error(slot_idx int) int
fn C.matrix_mcp_recover(slot_idx int) int
fn C.matrix_mcp_validate_token(ptr &u8, len usize) int
fn C.matrix_mcp_is_valid_action(action int) int
fn C.matrix_mcp_action_count() int
fn C.matrix_mcp_next_txn_id() u64
fn C.matrix_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 ABI exactly)
// ---------------------------------------------------------------------------

// Connection state: Disconnected(0) | Authenticating(1) | Connected(2) |
// Syncing(3) | Error(4)
enum ConnState {
	disconnected   = 0
	authenticating = 1
	connected      = 2
	syncing        = 3
	err            = 4
}

// All 16 Matrix actions.
enum MatrixAction {
	send_message     = 0
	send_event       = 1
	get_room         = 2
	list_rooms       = 3
	join_room        = 4
	leave_room       = 5
	invite_user      = 6
	kick_user        = 7
	set_room_state   = 8
	get_room_state   = 9
	sync             = 10
	search_messages  = 11
	upload_media     = 12
	get_profile      = 13
	set_display_name = 14
	create_room      = 15
}

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'authenticating' }
		2 { 'connected' }
		3 { 'syncing' }
		4 { 'error' }
		else { 'unknown' }
	}
}

fn action_label(a int) string {
	return match a {
		0 { 'send_message' }
		1 { 'send_event' }
		2 { 'get_room' }
		3 { 'list_rooms' }
		4 { 'join_room' }
		5 { 'leave_room' }
		6 { 'invite_user' }
		7 { 'kick_user' }
		8 { 'set_room_state' }
		9 { 'get_room_state' }
		10 { 'sync' }
		11 { 'search_messages' }
		12 { 'upload_media' }
		13 { 'get_profile' }
		14 { 'set_display_name' }
		15 { 'create_room' }
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
// Base URLs
// ---------------------------------------------------------------------------

const default_homeserver = 'https://matrix.org'
const api_prefix = '/_matrix/client/v3/'

// ---------------------------------------------------------------------------
// Adapter functions: session management
// ---------------------------------------------------------------------------

// Open a new session in Disconnected state.
pub fn session_open() !SessionResponse {
	slot := C.matrix_mcp_session_open()
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
	result := C.matrix_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

// Get current session state.
pub fn session_state(slot int) StateResponse {
	s := C.matrix_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

// ---------------------------------------------------------------------------
// Adapter functions: state transitions
// ---------------------------------------------------------------------------

// Begin authentication (Disconnected -> Authenticating).
pub fn authenticate(slot int) !string {
	result := C.matrix_mcp_authenticate(slot)
	return match result {
		0 { 'authenticating on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Complete authentication (Authenticating -> Connected).
pub fn connect(slot int) !string {
	result := C.matrix_mcp_connect(slot)
	return match result {
		0 { 'connected on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Begin sync (Connected -> Syncing).
pub fn begin_sync(slot int) !string {
	result := C.matrix_mcp_begin_sync(slot)
	return match result {
		0 { 'syncing on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// End sync (Syncing -> Connected).
pub fn end_sync(slot int) !string {
	result := C.matrix_mcp_end_sync(slot)
	return match result {
		0 { 'sync complete on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Signal an error on a session.
pub fn signal_error(slot int) !string {
	result := C.matrix_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Recover from error (Error -> Disconnected).
pub fn recover(slot int) !string {
	result := C.matrix_mcp_recover(slot)
	return match result {
		0 { 'recovered on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// ---------------------------------------------------------------------------
// Adapter functions: actions, validation, and txn IDs
// ---------------------------------------------------------------------------

// Validate a Matrix bearer token.
pub fn validate_token(token string) bool {
	return C.matrix_mcp_validate_token(token.str, token.len) == 1
}

// Check if a transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.matrix_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

// Check if an action code is valid.
pub fn is_valid_action(action int) ActionResponse {
	valid := C.matrix_mcp_is_valid_action(action) == 1
	return ActionResponse{ action: action_label(action), valid: valid }
}

// Get total action count.
pub fn action_count() int {
	return C.matrix_mcp_action_count()
}

// Generate the next transaction ID for idempotent PUT requests.
pub fn next_txn_id() u64 {
	return C.matrix_mcp_next_txn_id()
}

// Reset all sessions (test/debug only).
pub fn reset() {
	C.matrix_mcp_reset()
}
