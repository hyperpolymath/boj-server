// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hex_mcp_adapter.v — V-lang REST adapter for hex-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes Hex.pm package search, metadata retrieval, release listing,
// download stats, dependency analysis, owner listing, retirement checks,
// and user profile/package browsing.
// REST API: https://hex.pm/api

module hex_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lhex_mcp

fn C.hex_mcp_can_transition(from int, to int) int
fn C.hex_mcp_authenticate(dummy int) int
fn C.hex_mcp_open_anonymous(dummy int) int
fn C.hex_mcp_close(slot_idx int) int
fn C.hex_mcp_session_state(slot_idx int) int
fn C.hex_mcp_throttle(slot_idx int) int
fn C.hex_mcp_unthrottle(slot_idx int) int
fn C.hex_mcp_signal_error(slot_idx int) int
fn C.hex_mcp_record_call(slot_idx int, action int) int
fn C.hex_mcp_call_count(slot_idx int) int
fn C.hex_mcp_search_count(slot_idx int) int
fn C.hex_mcp_package_lookup_count(slot_idx int) int
fn C.hex_mcp_dep_query_count(slot_idx int) int
fn C.hex_mcp_owner_query_count(slot_idx int) int
fn C.hex_mcp_action_count() int
fn C.hex_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
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
	slot   int
	action int
	calls  int
}

struct StatusResponse {
	slot             int
	state            string
	call_count       int
	search_count     int
	package_lookups  int
	dep_queries      int
	owner_queries    int
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn authenticate() !AuthResponse {
	slot := C.hex_mcp_authenticate(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn open_anonymous() !AuthResponse {
	slot := C.hex_mcp_open_anonymous(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'unauthenticated'
	}
}

pub fn close(slot int) !string {
	result := C.hex_mcp_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.hex_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.hex_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('rate limited or in error state')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.hex_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.hex_mcp_session_state(slot)
	calls := C.hex_mcp_call_count(slot)
	searches := C.hex_mcp_search_count(slot)
	packages := C.hex_mcp_package_lookup_count(slot)
	deps := C.hex_mcp_dep_query_count(slot)
	owners := C.hex_mcp_owner_query_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: calls
		search_count: searches
		package_lookups: packages
		dep_queries: deps
		owner_queries: owners
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.hex_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.hex_mcp_reset()
}
