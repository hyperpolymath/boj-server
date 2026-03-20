// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// opam_mcp_adapter.v — V-lang REST adapter for opam-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes opam package search, metadata retrieval, version listing,
// dependency analysis, reverse dependency lookup, maintainer listing,
// tag retrieval, full package listing, and raw opam file access.
// REST API: https://opam.ocaml.org/api
// No auth required — fully public registry.

module opam_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lopam_mcp

fn C.opam_mcp_can_transition(from int, to int) int
fn C.opam_mcp_open(dummy int) int
fn C.opam_mcp_close(slot_idx int) int
fn C.opam_mcp_session_state(slot_idx int) int
fn C.opam_mcp_throttle(slot_idx int) int
fn C.opam_mcp_unthrottle(slot_idx int) int
fn C.opam_mcp_signal_error(slot_idx int) int
fn C.opam_mcp_record_call(slot_idx int, action int) int
fn C.opam_mcp_call_count(slot_idx int) int
fn C.opam_mcp_search_count(slot_idx int) int
fn C.opam_mcp_package_lookup_count(slot_idx int) int
fn C.opam_mcp_dep_query_count(slot_idx int) int
fn C.opam_mcp_revdep_query_count(slot_idx int) int
fn C.opam_mcp_action_count() int
fn C.opam_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {
	active       = 0
	rate_limited = 1
	err          = 2
}

fn state_label(s int) string {
	return match s {
		0 { 'active' }
		1 { 'rate_limited' }
		2 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct OpenResponse {
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
	revdep_queries   int
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn open_session() !OpenResponse {
	slot := C.opam_mcp_open(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return OpenResponse{
		slot: slot
		state: 'active'
	}
}

pub fn close(slot int) !string {
	result := C.opam_mcp_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.opam_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.opam_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('rate limited or in error state')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.opam_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.opam_mcp_session_state(slot)
	calls := C.opam_mcp_call_count(slot)
	searches := C.opam_mcp_search_count(slot)
	packages := C.opam_mcp_package_lookup_count(slot)
	deps := C.opam_mcp_dep_query_count(slot)
	revdeps := C.opam_mcp_revdep_query_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: calls
		search_count: searches
		package_lookups: packages
		dep_queries: deps
		revdep_queries: revdeps
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.opam_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.opam_mcp_reset()
}
