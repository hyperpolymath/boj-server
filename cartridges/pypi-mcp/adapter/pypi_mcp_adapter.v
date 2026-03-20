// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// pypi_mcp_adapter.v — V-lang REST adapter for pypi-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes PyPI package search, metadata retrieval, version listing,
// download stats, dependency analysis, release files, maintainer lookup,
// classifier browsing, vulnerability checks, and project URL extraction.
// REST API: https://pypi.org/pypi/<package>/json

module pypi_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lpypi_mcp

fn C.pypi_mcp_can_transition(from int, to int) int
fn C.pypi_mcp_authenticate(dummy int) int
fn C.pypi_mcp_open_anonymous(dummy int) int
fn C.pypi_mcp_close(slot_idx int) int
fn C.pypi_mcp_session_state(slot_idx int) int
fn C.pypi_mcp_throttle(slot_idx int) int
fn C.pypi_mcp_unthrottle(slot_idx int) int
fn C.pypi_mcp_signal_error(slot_idx int) int
fn C.pypi_mcp_record_call(slot_idx int, action int) int
fn C.pypi_mcp_call_count(slot_idx int) int
fn C.pypi_mcp_search_count(slot_idx int) int
fn C.pypi_mcp_package_lookup_count(slot_idx int) int
fn C.pypi_mcp_dep_query_count(slot_idx int) int
fn C.pypi_mcp_vuln_check_count(slot_idx int) int
fn C.pypi_mcp_action_count() int
fn C.pypi_mcp_reset()

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
	vuln_checks      int
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
	slot := C.pypi_mcp_authenticate(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn open_anonymous() !AuthResponse {
	slot := C.pypi_mcp_open_anonymous(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'unauthenticated'
	}
}

pub fn close(slot int) !string {
	result := C.pypi_mcp_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.pypi_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.pypi_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('rate limited or in error state')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.pypi_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.pypi_mcp_session_state(slot)
	calls := C.pypi_mcp_call_count(slot)
	searches := C.pypi_mcp_search_count(slot)
	packages := C.pypi_mcp_package_lookup_count(slot)
	deps := C.pypi_mcp_dep_query_count(slot)
	vulns := C.pypi_mcp_vuln_check_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: calls
		search_count: searches
		package_lookups: packages
		dep_queries: deps
		vuln_checks: vulns
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.pypi_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.pypi_mcp_reset()
}
