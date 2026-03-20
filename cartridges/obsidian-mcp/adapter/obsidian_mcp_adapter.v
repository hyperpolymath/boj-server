// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// obsidian_mcp_adapter.v — V-lang REST adapter for obsidian-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes Obsidian vault note search, content retrieval, backlink navigation,
// tag browsing, graph analysis, dataview queries, frontmatter extraction,
// daily notes, template listing, and vault statistics.
// REST API: https://127.0.0.1:27124 (Obsidian Local REST API)

module obsidian_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lobsidian_mcp

fn C.obsidian_mcp_can_transition(from int, to int) int
fn C.obsidian_mcp_connect(dummy int) int
fn C.obsidian_mcp_disconnect(slot_idx int) int
fn C.obsidian_mcp_session_state(slot_idx int) int
fn C.obsidian_mcp_throttle(slot_idx int) int
fn C.obsidian_mcp_unthrottle(slot_idx int) int
fn C.obsidian_mcp_signal_error(slot_idx int) int
fn C.obsidian_mcp_record_call(slot_idx int, action int) int
fn C.obsidian_mcp_call_count(slot_idx int) int
fn C.obsidian_mcp_search_count(slot_idx int) int
fn C.obsidian_mcp_note_read_count(slot_idx int) int
fn C.obsidian_mcp_link_query_count(slot_idx int) int
fn C.obsidian_mcp_tag_query_count(slot_idx int) int
fn C.obsidian_mcp_action_count() int
fn C.obsidian_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {
	disconnected = 0
	connected    = 1
	rate_limited = 2
	err          = 3
}

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'connected' }
		2 { 'rate_limited' }
		3 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct ConnectResponse {
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
	slot          int
	state         string
	call_count    int
	search_count  int
	note_reads    int
	link_queries  int
	tag_queries   int
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn connect() !ConnectResponse {
	slot := C.obsidian_mcp_connect(0)
	if slot == -1 {
		return error('no session slots available')
	}
	return ConnectResponse{
		slot: slot
		state: 'connected'
	}
}

pub fn disconnect(slot int) !string {
	result := C.obsidian_mcp_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.obsidian_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.obsidian_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not connected (rate limited, error, or disconnected)')
	}
	if result == -3 {
		return error('invalid action')
	}
	calls := C.obsidian_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.obsidian_mcp_session_state(slot)
	calls := C.obsidian_mcp_call_count(slot)
	searches := C.obsidian_mcp_search_count(slot)
	notes := C.obsidian_mcp_note_read_count(slot)
	links := C.obsidian_mcp_link_query_count(slot)
	tags := C.obsidian_mcp_tag_query_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		call_count: calls
		search_count: searches
		note_reads: notes
		link_queries: links
		tag_queries: tags
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.obsidian_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.obsidian_mcp_reset()
}
