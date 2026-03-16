// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// telegram_mcp_adapter.v — V-lang adapter for telegram-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Covers all 16 Telegram Bot API actions: messages, updates, chats, media,
// webhooks, callbacks, stickers, forwarding, pinning, and bot info.
// Auth: Bot token in URL path (https://api.telegram.org/bot{token}/{method}).
// Rate limiting: 30 messages per second global limit.

module telegram_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -ltelegram_mcp

fn C.telegram_mcp_can_transition(from int, to int) int
fn C.telegram_mcp_session_open() int
fn C.telegram_mcp_session_close(slot_idx int) int
fn C.telegram_mcp_session_state(slot_idx int) int
fn C.telegram_mcp_authenticate(slot_idx int) int
fn C.telegram_mcp_connect(slot_idx int) int
fn C.telegram_mcp_rate_limit(slot_idx int) int
fn C.telegram_mcp_signal_error(slot_idx int) int
fn C.telegram_mcp_recover(slot_idx int) int
fn C.telegram_mcp_validate_token(ptr &u8, len usize) int
fn C.telegram_mcp_is_valid_action(action int) int
fn C.telegram_mcp_action_count() int
fn C.telegram_mcp_global_rate_limit() int
fn C.telegram_mcp_reset()

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

// All 16 Telegram actions.
enum TelegramAction {
	send_message     = 0
	edit_message     = 1
	delete_message   = 2
	get_updates      = 3
	get_chat         = 4
	list_chats       = 5
	send_photo       = 6
	send_document    = 7
	set_webhook      = 8
	delete_webhook   = 9
	get_webhook_info = 10
	answer_callback  = 11
	send_sticker     = 12
	forward_message  = 13
	pin_message      = 14
	get_me           = 15
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
		3 { 'get_updates' }
		4 { 'get_chat' }
		5 { 'list_chats' }
		6 { 'send_photo' }
		7 { 'send_document' }
		8 { 'set_webhook' }
		9 { 'delete_webhook' }
		10 { 'get_webhook_info' }
		11 { 'answer_callback' }
		12 { 'send_sticker' }
		13 { 'forward_message' }
		14 { 'pin_message' }
		15 { 'get_me' }
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

const base_url = 'https://api.telegram.org/'

// ---------------------------------------------------------------------------
// Adapter functions: session management
// ---------------------------------------------------------------------------

// Open a new session in Disconnected state.
pub fn session_open() !SessionResponse {
	slot := C.telegram_mcp_session_open()
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
	result := C.telegram_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

// Get current session state.
pub fn session_state(slot int) StateResponse {
	s := C.telegram_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

// ---------------------------------------------------------------------------
// Adapter functions: state transitions
// ---------------------------------------------------------------------------

// Begin authentication (Disconnected -> Authenticating).
pub fn authenticate(slot int) !string {
	result := C.telegram_mcp_authenticate(slot)
	return match result {
		0 { 'authenticating on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Complete authentication (Authenticating -> Connected).
pub fn connect(slot int) !string {
	result := C.telegram_mcp_connect(slot)
	return match result {
		0 { 'connected on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Enter rate-limited state (Connected -> RateLimited).
pub fn rate_limit(slot int) !string {
	result := C.telegram_mcp_rate_limit(slot)
	return match result {
		0 { 'rate limited on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Signal an error on a session.
pub fn signal_error(slot int) !string {
	result := C.telegram_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

// Recover from error (Error -> Disconnected).
pub fn recover(slot int) !string {
	result := C.telegram_mcp_recover(slot)
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

// Validate a Telegram bot token (must contain colon, > 10 chars).
pub fn validate_token(token string) bool {
	return C.telegram_mcp_validate_token(token.str, token.len) == 1
}

// Check if a transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.telegram_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

// Check if an action code is valid.
pub fn is_valid_action(action int) ActionResponse {
	valid := C.telegram_mcp_is_valid_action(action) == 1
	return ActionResponse{ action: action_label(action), valid: valid }
}

// Get total action count.
pub fn action_count() int {
	return C.telegram_mcp_action_count()
}

// Get global rate limit (messages per second).
pub fn global_rate_limit() int {
	return C.telegram_mcp_global_rate_limit()
}

// Reset all sessions (test/debug only).
pub fn reset() {
	C.telegram_mcp_reset()
}
