// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// arango_mcp_adapter.v — V-lang REST adapter for the arango-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Auth: Bearer token (JWT) or Basic auth (username/password).
// API base: configurable (self-hosted) — default https://{host}:8529/_api/
// Multi-model database: document, graph, key-value, search.

module arango_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -larango_mcp

fn C.arango_mcp_can_transition(from int, to int) int
fn C.arango_mcp_session_open() int
fn C.arango_mcp_session_close(slot_idx int) int
fn C.arango_mcp_session_state(slot_idx int) int
fn C.arango_mcp_begin_query(slot_idx int) int
fn C.arango_mcp_end_query(slot_idx int) int
fn C.arango_mcp_signal_error(slot_idx int) int
fn C.arango_mcp_error_recover(slot_idx int) int
fn C.arango_mcp_query_count(slot_idx int) int
fn C.arango_mcp_record_document_op(slot_idx int) int
fn C.arango_mcp_document_op_count(slot_idx int) int
fn C.arango_mcp_action_requires_connection(action int) int
fn C.arango_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 ABI exactly)
// ---------------------------------------------------------------------------

enum ConnState {
	disconnected = 0
	connected    = 1
	query_running = 2
	err          = 3
}

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'connected' }
		2 { 'query_running' }
		3 { 'error' }
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
	from    int
	to      int
	valid   bool
}

struct QueryCountResponse {
	slot  int
	count int
}

struct DocumentOpCountResponse {
	slot  int
	count int
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn session_open() !SessionResponse {
	slot := C.arango_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'connected'
	}
}

pub fn session_close(slot int) !string {
	result := C.arango_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.arango_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn begin_query(slot int) !string {
	result := C.arango_mcp_begin_query(slot)
	return match result {
		0 { 'query running on slot ${slot}' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn end_query(slot int) !string {
	result := C.arango_mcp_end_query(slot)
	return match result {
		0 { 'query completed on slot ${slot}' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn error_recover(slot int) !string {
	result := C.arango_mcp_error_recover(slot)
	return match result {
		0 { 'recovered slot ${slot} to disconnected' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn query_count(slot int) QueryCountResponse {
	count := C.arango_mcp_query_count(slot)
	return QueryCountResponse{ slot: slot, count: count }
}

pub fn document_op_count(slot int) DocumentOpCountResponse {
	count := C.arango_mcp_document_op_count(slot)
	return DocumentOpCountResponse{ slot: slot, count: count }
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.arango_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.arango_mcp_reset()
}
