// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// google_sheets_mcp_adapter.v — V-lang REST adapter for google-sheets-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes Google Sheets spreadsheet metadata, cell range reading/writing,
// sheet listing, named ranges, row appending, sheet creation, batch reads,
// conditional formats, and pivot tables.
// REST API: https://sheets.googleapis.com/v4

module google_sheets_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lgoogle_sheets_mcp

fn C.google_sheets_mcp_can_transition(from int, to int) int
fn C.google_sheets_mcp_connect(dummy int) int
fn C.google_sheets_mcp_disconnect(slot_idx int) int
fn C.google_sheets_mcp_session_state(slot_idx int) int
fn C.google_sheets_mcp_throttle(slot_idx int) int
fn C.google_sheets_mcp_unthrottle(slot_idx int) int
fn C.google_sheets_mcp_signal_error(slot_idx int) int
fn C.google_sheets_mcp_record_call(slot_idx int, action int) int
fn C.google_sheets_mcp_call_count(slot_idx int) int
fn C.google_sheets_mcp_cell_read_count(slot_idx int) int
fn C.google_sheets_mcp_cell_write_count(slot_idx int) int
fn C.google_sheets_mcp_sheet_query_count(slot_idx int) int
fn C.google_sheets_mcp_format_query_count(slot_idx int) int
fn C.google_sheets_mcp_action_count() int
fn C.google_sheets_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {
	disconnected = 0
	connected    = 1
	rate_limited = 2
	err          = 3
}

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'connected' }
		2 { 'rate_limited' }
		3 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct ConnectResponse {
	slot  int
	state string
}

struct StateResponse {
	slot  int
	state string
}

struct ActionResponse {
	slot   int
	action int
	calls  int
}

struct StatusResponse {
	slot           int
	state          string
	call_count     int
	cell_reads     int
	cell_writes    int
	sheet_queries  int
	format_queries int
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn connect() !ConnectResponse {
	slot := C.google_sheets_mcp_connect(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return ConnectResponse{
		slot: slot
		state: 'connected'
	}
}

pub fn disconnect(slot int) !string {
	result := C.google_sheets_mcp_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.google_sheets_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.google_sheets_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not connected (rate limited, error, or disconnected)')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.google_sheets_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.google_sheets_mcp_session_state(slot)
	calls := C.google_sheets_mcp_call_count(slot)
	reads := C.google_sheets_mcp_cell_read_count(slot)
	writes := C.google_sheets_mcp_cell_write_count(slot)
	sheets := C.google_sheets_mcp_sheet_query_count(slot)
	formats := C.google_sheets_mcp_format_query_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: calls
		cell_reads: reads
		cell_writes: writes
		sheet_queries: sheets
		format_queries: formats
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.google_sheets_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.google_sheets_mcp_reset()
}
