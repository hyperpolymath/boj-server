// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// gcp_mcp_adapter.v — V-lang REST adapter for gcp-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes GCP service account/OAuth2 authentication, multi-service routing
// (Compute/Storage/Functions/PubSub/BigQuery/IAM), quota tracking, and
// action invocation.

module gcp_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lgcp_mcp

fn C.gcp_mcp_can_transition(from int, to int) int
fn C.gcp_mcp_authenticate(project_ptr &u8, project_len int) int
fn C.gcp_mcp_deauthenticate(slot_idx int) int
fn C.gcp_mcp_session_state(slot_idx int) int
fn C.gcp_mcp_throttle(slot_idx int) int
fn C.gcp_mcp_unthrottle(slot_idx int) int
fn C.gcp_mcp_signal_error(slot_idx int) int
fn C.gcp_mcp_action_service(action int) int
fn C.gcp_mcp_record_call(slot_idx int, action int) int
fn C.gcp_mcp_call_count(slot_idx int) int
fn C.gcp_mcp_quota_remaining(slot_idx int) int
fn C.gcp_mcp_service_count() int
fn C.gcp_mcp_action_count() int
fn C.gcp_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
}

enum GcpService {
	compute   = 0
	storage   = 1
	functions = 2
	pubsub    = 3
	bigquery  = 4
	iam       = 5
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

fn service_label(s int) string {
	return match s {
		0 { 'compute' }
		1 { 'storage' }
		2 { 'functions' }
		3 { 'pubsub' }
		4 { 'bigquery' }
		5 { 'iam' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct AuthResponse {
	slot       int
	state      string
	project_id string
}

struct StateResponse {
	slot  int
	state string
}

struct ActionResponse {
	slot    int
	action  int
	service string
	calls   int
}

struct StatusResponse {
	slot            int
	state           string
	project_id      string
	service_count   int
	call_count      int
	quota_remaining int
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn authenticate(project_id string) !AuthResponse {
	slot := C.gcp_mcp_authenticate(project_id.str, project_id.len)
	if slot == -1 {
		return error('no session slots available')
	}
	if slot == -2 {
		return error('project_id string too long')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
		project_id: project_id
	}
}

pub fn deauthenticate(slot int) !string {
	result := C.gcp_mcp_deauthenticate(slot)
	return match result {
		0 { 'deauthenticated slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.gcp_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.gcp_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not authenticated')
	}
	if result == -3 {
		return error('invalid action')
	}
	svc := C.gcp_mcp_action_service(action)
	calls := C.gcp_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		service: service_label(svc)
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.gcp_mcp_session_state(slot)
	calls := C.gcp_mcp_call_count(slot)
	quota := C.gcp_mcp_quota_remaining(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		project_id: ''
		service_count: C.gcp_mcp_service_count()
		call_count: calls
		quota_remaining: quota
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.gcp_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.gcp_mcp_reset()
}
