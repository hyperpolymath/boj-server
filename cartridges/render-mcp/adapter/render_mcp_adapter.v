// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// render_mcp_adapter.v -- V-lang REST adapter for render-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Render REST API v1 (https://api.render.com/v1/), Bearer token auth.
// Rate limit: 100 req/min.

module render_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lrender_mcp

fn C.render_mcp_can_transition(from int, to int) int
fn C.render_mcp_session_open() int
fn C.render_mcp_session_close(slot_idx int) int
fn C.render_mcp_session_state(slot_idx int) int
fn C.render_mcp_rate_limit(slot_idx int) int
fn C.render_mcp_rate_recover(slot_idx int) int
fn C.render_mcp_signal_error(slot_idx int) int
fn C.render_mcp_error_recover(slot_idx int) int
fn C.render_mcp_action_requires_auth(action int) int
fn C.render_mcp_rate_limit_per_minute() int
fn C.render_mcp_service_count(slot_idx int) int
fn C.render_mcp_set_service_count(slot_idx int, count int) int
fn C.render_mcp_deploy_ok(slot_idx int) int
fn C.render_mcp_deploy_fail(slot_idx int) int
fn C.render_mcp_set_deploy_counts(slot_idx int, ok int, fail int) int
fn C.render_mcp_bandwidth_mb(slot_idx int) int
fn C.render_mcp_set_bandwidth_mb(slot_idx int, mb int) int
fn C.render_mcp_reset()

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
	service_count int
	deploy_ok     int
	deploy_fail   int
	bandwidth_mb  int
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn session_open() !SessionResponse {
	slot := C.render_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn session_close(slot int) !string {
	result := C.render_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.render_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn rate_limit(slot int) !string {
	result := C.render_mcp_rate_limit(slot)
	return match result {
		0 { 'rate limited on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn rate_recover(slot int) !string {
	result := C.render_mcp_rate_recover(slot)
	return match result {
		0 { 'recovered from rate limit on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn signal_error(slot int) !string {
	result := C.render_mcp_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.render_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn get_metrics(slot int) MetricsResponse {
	return MetricsResponse{
		slot: slot
		service_count: C.render_mcp_service_count(slot)
		deploy_ok: C.render_mcp_deploy_ok(slot)
		deploy_fail: C.render_mcp_deploy_fail(slot)
		bandwidth_mb: C.render_mcp_bandwidth_mb(slot)
	}
}

pub fn reset() {
	C.render_mcp_reset()
}
