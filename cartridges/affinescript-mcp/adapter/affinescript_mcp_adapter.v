// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// affinescript_mcp_adapter.v — V-lang REST adapter for affinescript-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes AffineScript type checking, parsing, formatting, error explanation,
// stdlib browsing, syntax reference, and snippet evaluation.
// Local compiler: `affinescript` CLI (OCaml)
// No auth required — local tool invocation.

module affinescript_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -laffinescript_mcp

fn C.afs_mcp_can_transition(from int, to int) int
fn C.afs_mcp_open(dummy int) int
fn C.afs_mcp_close(slot_idx int) int
fn C.afs_mcp_session_state(slot_idx int) int
fn C.afs_mcp_start_invocation(slot_idx int) int
fn C.afs_mcp_finish_success(slot_idx int) int
fn C.afs_mcp_signal_error(slot_idx int) int
fn C.afs_mcp_recover(slot_idx int) int
fn C.afs_mcp_record_action(slot_idx int, action int) int
fn C.afs_mcp_invocation_count(slot_idx int) int
fn C.afs_mcp_check_count(slot_idx int) int
fn C.afs_mcp_parse_count(slot_idx int) int
fn C.afs_mcp_format_count(slot_idx int) int
fn C.afs_mcp_action_count() int
fn C.afs_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {
	ready = 0
	busy  = 1
	err   = 2
}

fn state_label(s int) string {
	return match s {
		0 { 'ready' }
		1 { 'busy' }
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
	invocation_count int
	check_count      int
	parse_count      int
	format_count     int
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
	slot := C.afs_mcp_open(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return OpenResponse{
		slot: slot
		state: 'ready'
	}
}

pub fn close(slot int) !string {
	result := C.afs_mcp_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.afs_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.afs_mcp_record_action(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.afs_mcp_invocation_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.afs_mcp_session_state(slot)
	calls := C.afs_mcp_invocation_count(slot)
	checks := C.afs_mcp_check_count(slot)
	parses := C.afs_mcp_parse_count(slot)
	formats := C.afs_mcp_format_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		invocation_count: calls
		check_count: checks
		parse_count: parses
		format_count: formats
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.afs_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.afs_mcp_reset()
}
