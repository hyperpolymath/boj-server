// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// fly_mcp_adapter.v -- V-lang REST adapter for fly-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Fly.io Machines API v1 (https://api.machines.dev/v1/), Bearer token auth.

module fly_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lfly_mcp

fn C.fly_mcp_can_transition(from int, to int) int
fn C.fly_mcp_session_open() int
fn C.fly_mcp_session_close(slot_idx int) int
fn C.fly_mcp_session_state(slot_idx int) int
fn C.fly_mcp_rate_limit(slot_idx int) int
fn C.fly_mcp_rate_recover(slot_idx int) int
fn C.fly_mcp_signal_error(slot_idx int) int
fn C.fly_mcp_error_recover(slot_idx int) int
fn C.fly_mcp_action_requires_auth(action int) int
fn C.fly_mcp_app_count(slot_idx int) int
fn C.fly_mcp_machine_count(slot_idx int) int
fn C.fly_mcp_set_app_count(slot_idx int, count int) int
fn C.fly_mcp_set_machine_count(slot_idx int, count int) int
fn C.fly_mcp_reset()

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
	slot          int
	app_count     int
	machine_count int
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn session_open() !SessionResponse {
	slot := C.fly_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn session_close(slot int) !string {
	result := C.fly_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.fly_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn rate_limit(slot int) !string {
	result := C.fly_mcp_rate_limit(slot)
	return match result {
		0 { 'rate limited on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn rate_recover(slot int) !string {
	result := C.fly_mcp_rate_recover(slot)
	return match result {
		0 { 'recovered from rate limit on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn signal_error(slot int) !string {
	result := C.fly_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.fly_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn get_metrics(slot int) MetricsResponse {
	return MetricsResponse{
		slot: slot
		app_count: C.fly_mcp_app_count(slot)
		machine_count: C.fly_mcp_machine_count(slot)
	}
}

pub fn reset() {
	C.fly_mcp_reset()
}
