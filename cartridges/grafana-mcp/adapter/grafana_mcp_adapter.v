// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// grafana_mcp_adapter.v — V-lang REST adapter for grafana-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes Grafana dashboard CRUD, datasource queries, alert listing,
// annotation creation, folder browsing, and health checks.
// API: Grafana HTTP API (/api/*)

module grafana_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lgrafana_mcp

fn C.grafana_mcp_can_transition(from int, to int) int
fn C.grafana_mcp_authenticate(dummy int) int
fn C.grafana_mcp_close(slot_idx int) int
fn C.grafana_mcp_session_state(slot_idx int) int
fn C.grafana_mcp_throttle(slot_idx int) int
fn C.grafana_mcp_unthrottle(slot_idx int) int
fn C.grafana_mcp_signal_error(slot_idx int) int
fn C.grafana_mcp_record_call(slot_idx int, action int) int
fn C.grafana_mcp_call_count(slot_idx int) int
fn C.grafana_mcp_dashboard_op_count(slot_idx int) int
fn C.grafana_mcp_query_count(slot_idx int) int
fn C.grafana_mcp_alert_check_count(slot_idx int) int
fn C.grafana_mcp_action_count() int
fn C.grafana_mcp_reset()

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
	slot            int
	state           string
	call_count      int
	dashboard_ops   int
	query_count     int
	alert_checks    int
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
	slot := C.grafana_mcp_authenticate(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn close(slot int) !string {
	result := C.grafana_mcp_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.grafana_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.grafana_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not authenticated, rate limited, or in error state')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.grafana_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.grafana_mcp_session_state(slot)
	calls := C.grafana_mcp_call_count(slot)
	dashboards := C.grafana_mcp_dashboard_op_count(slot)
	queries := C.grafana_mcp_query_count(slot)
	alerts := C.grafana_mcp_alert_check_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: calls
		dashboard_ops: dashboards
		query_count: queries
		alert_checks: alerts
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.grafana_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.grafana_mcp_reset()
}
