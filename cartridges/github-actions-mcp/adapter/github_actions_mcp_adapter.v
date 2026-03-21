// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// github_actions_mcp_adapter.v — V-lang REST adapter for github-actions-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes GitHub Actions workflow listing, run management, job inspection,
// artifact listing, log retrieval, dispatch, re-run, cancellation,
// secret listing, runner listing, and cache management.
// API: GitHub Actions REST API

module github_actions_mcp_adapter

#flag -L../../ffi/zig-out/lib
#flag -lgithub_actions_mcp

fn C.gha_mcp_can_transition(from int, to int) int
fn C.gha_mcp_authenticate(dummy int) int
fn C.gha_mcp_close(slot_idx int) int
fn C.gha_mcp_session_state(slot_idx int) int
fn C.gha_mcp_throttle(slot_idx int) int
fn C.gha_mcp_unthrottle(slot_idx int) int
fn C.gha_mcp_signal_error(slot_idx int) int
fn C.gha_mcp_record_call(slot_idx int, action int) int
fn C.gha_mcp_call_count(slot_idx int) int
fn C.gha_mcp_workflow_op_count(slot_idx int) int
fn C.gha_mcp_run_op_count(slot_idx int) int
fn C.gha_mcp_infra_op_count(slot_idx int) int
fn C.gha_mcp_action_count() int
fn C.gha_mcp_reset()

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

struct AuthResponse {
	slot  int
	state string
}

struct StatusResponse {
	slot          int
	state         string
	call_count    int
	workflow_ops  int
	run_ops       int
	infra_ops     int
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

pub fn authenticate() !AuthResponse {
	slot := C.gha_mcp_authenticate(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
	}
}

pub fn close(slot int) !string {
	result := C.gha_mcp_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.gha_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not authenticated, rate limited, or in error state')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.gha_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.gha_mcp_session_state(slot)
	calls := C.gha_mcp_call_count(slot)
	workflows := C.gha_mcp_workflow_op_count(slot)
	runs := C.gha_mcp_run_op_count(slot)
	infra := C.gha_mcp_infra_op_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: calls
		workflow_ops: workflows
		run_ops: runs
		infra_ops: infra
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.gha_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.gha_mcp_reset()
}
