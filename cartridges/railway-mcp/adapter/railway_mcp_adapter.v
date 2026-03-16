// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// railway_mcp_adapter.v -- V-lang GraphQL adapter for railway-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Railway GraphQL API v2 (https://backboard.railway.app/graphql/v2), Bearer token auth.

module railway_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lrailway_mcp

fn C.railway_mcp_can_transition(from int, to int) int
fn C.railway_mcp_session_open() int
fn C.railway_mcp_session_close(slot_idx int) int
fn C.railway_mcp_session_state(slot_idx int) int
fn C.railway_mcp_rate_limit(slot_idx int) int
fn C.railway_mcp_rate_recover(slot_idx int) int
fn C.railway_mcp_signal_error(slot_idx int) int
fn C.railway_mcp_error_recover(slot_idx int) int
fn C.railway_mcp_action_requires_auth(action int) int
fn C.railway_mcp_project_count(slot_idx int) int
fn C.railway_mcp_set_project_count(slot_idx int, count int) int
fn C.railway_mcp_service_count(slot_idx int) int
fn C.railway_mcp_set_service_count(slot_idx int, count int) int
fn C.railway_mcp_deployment_ok(slot_idx int) int
fn C.railway_mcp_deployment_fail(slot_idx int) int
fn C.railway_mcp_set_deployment_counts(slot_idx int, ok int, fail int) int
fn C.railway_mcp_reset()

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

struct MetricsResponse {
	slot            int
	project_count   int
	service_count   int
	deployment_ok   int
	deployment_fail int
}

// ---------------------------------------------------------------------------
// Adapter functions (GraphQL API bridge)
// ---------------------------------------------------------------------------

pub fn session_open() !SessionResponse {
	slot := C.railway_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn session_close(slot int) !string {
	result := C.railway_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.railway_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn rate_limit(slot int) !string {
	result := C.railway_mcp_rate_limit(slot)
	return match result {
		0 { 'rate limited on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn rate_recover(slot int) !string {
	result := C.railway_mcp_rate_recover(slot)
	return match result {
		0 { 'recovered from rate limit on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn signal_error(slot int) !string {
	result := C.railway_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.railway_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn get_metrics(slot int) MetricsResponse {
	return MetricsResponse{
		slot: slot
		project_count: C.railway_mcp_project_count(slot)
		service_count: C.railway_mcp_service_count(slot)
		deployment_ok: C.railway_mcp_deployment_ok(slot)
		deployment_fail: C.railway_mcp_deployment_fail(slot)
	}
}

pub fn reset() {
	C.railway_mcp_reset()
}
