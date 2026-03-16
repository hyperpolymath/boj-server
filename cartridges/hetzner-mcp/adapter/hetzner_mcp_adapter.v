// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// hetzner_mcp_adapter.v — V-lang REST adapter for hetzner-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes Hetzner Cloud Bearer token authentication, server/volume/firewall/
// network management, and per-second rate limiting.
// REST API: https://api.hetzner.cloud/v1/

module hetzner_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lhetzner_mcp

fn C.hetzner_mcp_can_transition(from int, to int) int
fn C.hetzner_mcp_authenticate(rate_limit int) int
fn C.hetzner_mcp_deauthenticate(slot_idx int) int
fn C.hetzner_mcp_session_state(slot_idx int) int
fn C.hetzner_mcp_throttle(slot_idx int) int
fn C.hetzner_mcp_unthrottle(slot_idx int) int
fn C.hetzner_mcp_signal_error(slot_idx int) int
fn C.hetzner_mcp_action_resource(action int) int
fn C.hetzner_mcp_record_call(slot_idx int, action int) int
fn C.hetzner_mcp_call_count(slot_idx int) int
fn C.hetzner_mcp_set_counts(slot_idx int, servers int, volumes int, firewalls int) int
fn C.hetzner_mcp_server_count(slot_idx int) int
fn C.hetzner_mcp_volume_count(slot_idx int) int
fn C.hetzner_mcp_firewall_count(slot_idx int) int
fn C.hetzner_mcp_resource_count() int
fn C.hetzner_mcp_action_count() int
fn C.hetzner_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
}

enum HetznerResource {
	servers   = 0
	images    = 1
	ssh_keys  = 2
	volumes   = 3
	firewalls = 4
	networks  = 5
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

fn resource_label(r int) string {
	return match r {
		0 { 'servers' }
		1 { 'images' }
		2 { 'ssh_keys' }
		3 { 'volumes' }
		4 { 'firewalls' }
		5 { 'networks' }
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
	slot     int
	action   int
	resource string
	calls    int
}

struct StatusResponse {
	slot           int
	state          string
	server_count   int
	volume_count   int
	firewall_count int
	call_count     int
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn authenticate(rate_limit int) !AuthResponse {
	slot := C.hetzner_mcp_authenticate(rate_limit)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn deauthenticate(slot int) !string {
	result := C.hetzner_mcp_deauthenticate(slot)
	return match result {
		0 { 'deauthenticated slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.hetzner_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.hetzner_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not authenticated')
	}
	if result == -3 {
		return error('invalid action')
	}
	res := C.hetzner_mcp_action_resource(action)
	calls := C.hetzner_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		resource: resource_label(res)
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.hetzner_mcp_session_state(slot)
	calls := C.hetzner_mcp_call_count(slot)
	servers := C.hetzner_mcp_server_count(slot)
	volumes := C.hetzner_mcp_volume_count(slot)
	firewalls := C.hetzner_mcp_firewall_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		server_count: servers
		volume_count: volumes
		firewall_count: firewalls
		call_count: calls
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.hetzner_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.hetzner_mcp_reset()
}
