// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// browser_mcp_adapter.v — V-lang REST adapter for browser-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Provides REST endpoints for Firefox browser automation via the Marionette
// protocol (TCP localhost:2828).

module browser_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lbrowser_mcp

// Session management
fn C.browser_mcp_session_open() int
fn C.browser_mcp_session_close(slot_idx int) int
fn C.browser_mcp_session_state(slot_idx int) int
fn C.browser_mcp_reset()

// Connection lifecycle
fn C.browser_mcp_connect(slot_idx int) int
fn C.browser_mcp_disconnect(slot_idx int) int

// Browser actions
fn C.browser_mcp_navigate(slot_idx int, url_ptr &u8, url_len int) int
fn C.browser_mcp_click(slot_idx int, selector_ptr &u8, selector_len int) int
fn C.browser_mcp_type(slot_idx int, selector_ptr &u8, selector_len int, text_ptr &u8, text_len int) int
fn C.browser_mcp_screenshot(slot_idx int, out_buf &u8, out_buf_len int) int
fn C.browser_mcp_read_page(slot_idx int, out_buf &u8, out_buf_len int) int

// Tab management
fn C.browser_mcp_tab_create(slot_idx int) int
fn C.browser_mcp_tab_close(slot_idx int, tab_idx int) int
fn C.browser_mcp_tab_list(slot_idx int, out_buf &u8, out_buf_len int) int

// State machine
fn C.browser_mcp_can_transition(from int, to int) int
fn C.browser_mcp_signal_error(slot_idx int) int
fn C.browser_mcp_error_recover(slot_idx int) int

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

/// Browser connection state.
enum BrowserState {
	closed     = 0
	connecting = 1
	connected  = 2
	navigating = 3
	err        = 4
}

/// Browser actions available via MCP tools.
enum BrowserAction {
	navigate   = 0
	click      = 1
	type_text  = 2
	screenshot = 3
	read_page  = 4
	fill_form  = 5
	execute_js = 6
	tab_create = 7
	tab_close  = 8
	tab_list   = 9
}

/// Map state integer to human-readable label.
fn state_label(s int) string {
	return match s {
		0 { 'closed' }
		1 { 'connecting' }
		2 { 'connected' }
		3 { 'navigating' }
		4 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Response for session open/connect operations.
struct SessionResponse {
	slot  int
	state string
}

/// Response for state queries.
struct StateResponse {
	slot  int
	state string
}

/// Response for state transition checks.
struct TransitionResponse {
	from  int
	to    int
	valid bool
}

/// Response for navigate operations.
struct NavigateResponse {
	slot int
	url  string
}

/// Response for click/type operations.
struct ActionResponse {
	slot   int
	action string
	target string
}

/// Response for screenshot/read_page operations returning data.
struct DataResponse {
	slot      int
	action    string
	data_len  int
	data      string
}

/// Response for tab operations.
struct TabResponse {
	slot      int
	tab_index int
}

/// Response for tab listing.
struct TabListResponse {
	slot       int
	tab_count  string
}

// ---------------------------------------------------------------------------
// Adapter functions — session management (REST: POST /session, DELETE /session)
// ---------------------------------------------------------------------------

/// Open a new browser session.
/// REST: POST /session -> SessionResponse
pub fn session_open() !SessionResponse {
	slot := C.browser_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'closed'
	}
}

/// Close a browser session.
/// REST: DELETE /session/{slot}
pub fn session_close(slot int) !string {
	result := C.browser_mcp_session_close(slot)
	return match result {
		0 { 'closed session ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Get the current state of a session.
/// REST: GET /session/{slot}/state
pub fn session_state(slot int) StateResponse {
	s := C.browser_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

// ---------------------------------------------------------------------------
// Adapter functions — connection lifecycle (REST: POST /connect, POST /disconnect)
// ---------------------------------------------------------------------------

/// Connect to Firefox Marionette on localhost:2828.
/// REST: POST /session/{slot}/connect
pub fn connect(slot int) !SessionResponse {
	result := C.browser_mcp_connect(slot)
	return match result {
		0 { SessionResponse{ slot: slot, state: 'connected' } }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition (must be in closed state)') }
		else { return error('connection error (code ${result})') }
	}
}

/// Disconnect from Firefox Marionette.
/// REST: POST /session/{slot}/disconnect
pub fn disconnect(slot int) !SessionResponse {
	result := C.browser_mcp_disconnect(slot)
	return match result {
		0 { SessionResponse{ slot: slot, state: 'closed' } }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition (must be in connected state)') }
		else { return error('disconnect error (code ${result})') }
	}
}

// ---------------------------------------------------------------------------
// Adapter functions — browser actions (REST: POST /navigate, POST /click, etc.)
// ---------------------------------------------------------------------------

/// Navigate to a URL in the current tab.
/// REST: POST /session/{slot}/navigate  body: { "url": "..." }
pub fn navigate(slot int, url string) !NavigateResponse {
	result := C.browser_mcp_navigate(slot, url.str, url.len)
	return match result {
		0 { NavigateResponse{ slot: slot, url: url } }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('not connected to browser') }
		-3 { return error('url too long') }
		else { return error('navigate error (code ${result})') }
	}
}

/// Click an element matching a CSS selector.
/// REST: POST /session/{slot}/click  body: { "selector": "..." }
pub fn click(slot int, selector string) !ActionResponse {
	result := C.browser_mcp_click(slot, selector.str, selector.len)
	return match result {
		0 { ActionResponse{ slot: slot, action: 'click', target: selector } }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('not connected to browser') }
		-3 { return error('invalid selector') }
		else { return error('click error (code ${result})') }
	}
}

/// Type text into an element matching a CSS selector.
/// REST: POST /session/{slot}/type  body: { "selector": "...", "text": "..." }
pub fn type_text(slot int, selector string, text string) !ActionResponse {
	result := C.browser_mcp_type(slot, selector.str, selector.len, text.str, text.len)
	return match result {
		0 { ActionResponse{ slot: slot, action: 'type', target: selector } }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('not connected to browser') }
		-3 { return error('invalid selector or text') }
		else { return error('type error (code ${result})') }
	}
}

/// Capture a screenshot of the current viewport.
/// REST: POST /session/{slot}/screenshot -> DataResponse (base64 PNG)
pub fn screenshot(slot int) !DataResponse {
	mut buf := []u8{len: 65536}
	result := C.browser_mcp_screenshot(slot, buf.data, buf.len)
	if result < 0 {
		return match result {
			-1 { error('slot ${slot} not active') }
			-2 { error('not connected to browser') }
			else { error('screenshot error (code ${result})') }
		}
	}
	return DataResponse{
		slot: slot
		action: 'screenshot'
		data_len: result
		data: buf[..result].bytestr()
	}
}

/// Read the DOM text content of the current page.
/// REST: POST /session/{slot}/read_page -> DataResponse
pub fn read_page(slot int) !DataResponse {
	mut buf := []u8{len: 65536}
	result := C.browser_mcp_read_page(slot, buf.data, buf.len)
	if result < 0 {
		return match result {
			-1 { error('slot ${slot} not active') }
			-2 { error('not connected to browser') }
			else { error('read_page error (code ${result})') }
		}
	}
	return DataResponse{
		slot: slot
		action: 'read_page'
		data_len: result
		data: buf[..result].bytestr()
	}
}

// ---------------------------------------------------------------------------
// Adapter functions — tab management (REST: POST /tab, DELETE /tab, GET /tabs)
// ---------------------------------------------------------------------------

/// Create a new browser tab.
/// REST: POST /session/{slot}/tab -> TabResponse
pub fn tab_create(slot int) !TabResponse {
	result := C.browser_mcp_tab_create(slot)
	if result < 0 {
		return match result {
			-1 { error('slot ${slot} not active') }
			-2 { error('not connected to browser') }
			-3 { error('tab limit reached') }
			else { error('tab_create error (code ${result})') }
		}
	}
	return TabResponse{ slot: slot, tab_index: result }
}

/// Close a tab by index.
/// REST: DELETE /session/{slot}/tab/{tab_idx}
pub fn tab_close(slot int, tab_idx int) !string {
	result := C.browser_mcp_tab_close(slot, tab_idx)
	return match result {
		0 { 'closed tab ${tab_idx} on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('not connected to browser') }
		-3 { return error('invalid tab index ${tab_idx}') }
		else { return error('tab_close error (code ${result})') }
	}
}

/// List all open tabs.
/// REST: GET /session/{slot}/tabs -> TabListResponse
pub fn tab_list(slot int) !TabListResponse {
	mut buf := []u8{len: 4096}
	result := C.browser_mcp_tab_list(slot, buf.data, buf.len)
	if result < 0 {
		return match result {
			-1 { error('slot ${slot} not active') }
			-2 { error('not connected to browser') }
			else { error('tab_list error (code ${result})') }
		}
	}
	return TabListResponse{
		slot: slot
		tab_count: buf[..result].bytestr()
	}
}

// ---------------------------------------------------------------------------
// Adapter functions — state machine utilities
// ---------------------------------------------------------------------------

/// Check if a state transition is valid.
/// REST: GET /transition?from={from}&to={to}
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.browser_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Signal an error on a session.
/// REST: POST /session/{slot}/error
pub fn signal_error(slot int) !string {
	result := C.browser_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Recover from error state.
/// REST: POST /session/{slot}/recover
pub fn error_recover(slot int) !string {
	result := C.browser_mcp_error_recover(slot)
	return match result {
		0 { 'recovered slot ${slot} to closed state' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition (must be in error state)') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Reset all sessions (test/debug use only).
pub fn reset() {
	C.browser_mcp_reset()
}
