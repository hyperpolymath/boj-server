// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// circleci_mcp_adapter.v — V-lang REST adapter for circleci-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes CircleCI pipeline listing, workflow management, job inspection,
// artifact retrieval, pipeline triggering, workflow cancellation,
// and environment variable browsing.
// API: CircleCI API v2

module circleci_mcp_adapter

#flag -L../../ffi/zig-out/lib
#flag -lcircleci_mcp

fn C.circleci_mcp_can_transition(from int, to int) int
fn C.circleci_mcp_authenticate(dummy int) int
fn C.circleci_mcp_close(slot_idx int) int
fn C.circleci_mcp_session_state(slot_idx int) int
fn C.circleci_mcp_throttle(slot_idx int) int
fn C.circleci_mcp_unthrottle(slot_idx int) int
fn C.circleci_mcp_signal_error(slot_idx int) int
fn C.circleci_mcp_record_call(slot_idx int, action int) int
fn C.circleci_mcp_call_count(slot_idx int) int
fn C.circleci_mcp_pipeline_op_count(slot_idx int) int
fn C.circleci_mcp_workflow_op_count(slot_idx int) int
fn C.circleci_mcp_config_op_count(slot_idx int) int
fn C.circleci_mcp_action_count() int
fn C.circleci_mcp_reset()

fn state_label(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'rate_limited' }
		3 { 'error' }
		else { 'unknown' }
	}
}

struct AuthResponse { slot int  state string }
struct StatusResponse { slot int  state string  call_count int  pipeline_ops int  workflow_ops int  config_ops int }
struct ActionResponse { slot int  action int  calls int }
struct TransitionResponse { from int  to int  valid bool }

pub fn authenticate() !AuthResponse {
	slot := C.circleci_mcp_authenticate(0)
	if slot == -1 { return error('no session slots available') }
	return AuthResponse{ slot: slot, state: 'authenticated' }
}

pub fn close(slot int) !string {
	result := C.circleci_mcp_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.circleci_mcp_record_call(slot, action)
	if result == -1 { return error('slot not active') }
	if result == -2 { return error('not authenticated, rate limited, or in error state') }
	if result == -3 { return error('invalid action') }
	calls := C.circleci_mcp_call_count(slot)
	return ActionResponse{ slot: slot, action: action, calls: calls }
}

pub fn status(slot int) StatusResponse {
	s := C.circleci_mcp_session_state(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: C.circleci_mcp_call_count(slot)
		pipeline_ops: C.circleci_mcp_pipeline_op_count(slot)
		workflow_ops: C.circleci_mcp_workflow_op_count(slot)
		config_ops: C.circleci_mcp_config_op_count(slot)
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	return TransitionResponse{ from: from, to: to, valid: C.circleci_mcp_can_transition(from, to) == 1 }
}

pub fn reset() { C.circleci_mcp_reset() }
