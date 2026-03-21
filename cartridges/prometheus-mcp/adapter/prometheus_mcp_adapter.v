// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// prometheus_mcp_adapter.v — V-lang REST adapter for prometheus-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes Prometheus instant/range PromQL queries, target discovery,
// alert listing, label browsing, metadata, and series listing.
// API: Prometheus HTTP API v1 (/api/v1/*)

module prometheus_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lprometheus_mcp

fn C.prometheus_mcp_can_transition(from int, to int) int
fn C.prometheus_mcp_authenticate(dummy int) int
fn C.prometheus_mcp_open_anonymous(dummy int) int
fn C.prometheus_mcp_close(slot_idx int) int
fn C.prometheus_mcp_session_state(slot_idx int) int
fn C.prometheus_mcp_throttle(slot_idx int) int
fn C.prometheus_mcp_unthrottle(slot_idx int) int
fn C.prometheus_mcp_signal_error(slot_idx int) int
fn C.prometheus_mcp_record_call(slot_idx int, action int) int
fn C.prometheus_mcp_call_count(slot_idx int) int
fn C.prometheus_mcp_instant_query_count(slot_idx int) int
fn C.prometheus_mcp_range_query_count(slot_idx int) int
fn C.prometheus_mcp_discovery_count(slot_idx int) int
fn C.prometheus_mcp_action_count() int
fn C.prometheus_mcp_reset()

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

struct StatusResponse {
	slot             int
	state            string
	call_count       int
	instant_queries  int
	range_queries    int
	discovery_ops    int
}

struct ActionResponse {
	slot   int
	action int
	calls  int
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
	slot := C.prometheus_mcp_authenticate(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn open_anonymous() !AuthResponse {
	slot := C.prometheus_mcp_open_anonymous(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'unauthenticated'
	}
}

pub fn close(slot int) !string {
	result := C.prometheus_mcp_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.prometheus_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('rate limited or in error state')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.prometheus_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.prometheus_mcp_session_state(slot)
	calls := C.prometheus_mcp_call_count(slot)
	instant := C.prometheus_mcp_instant_query_count(slot)
	range_q := C.prometheus_mcp_range_query_count(slot)
	discovery := C.prometheus_mcp_discovery_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: calls
		instant_queries: instant
		range_queries: range_q
		discovery_ops: discovery
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.prometheus_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.prometheus_mcp_reset()
}
