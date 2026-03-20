// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// duckdb_mcp_adapter.v — V-lang adapter for the duckdb-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Auth: None (DuckDB is embedded, runs in-process).
// Supports SQL queries, Parquet/CSV import and export, database attach/detach.

module duckdb_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lduckdb_mcp

fn C.duckdb_mcp_can_transition(from int, to int) int
fn C.duckdb_mcp_session_open() int
fn C.duckdb_mcp_session_close(slot_idx int) int
fn C.duckdb_mcp_session_state(slot_idx int) int
fn C.duckdb_mcp_begin_query(slot_idx int) int
fn C.duckdb_mcp_end_query(slot_idx int) int
fn C.duckdb_mcp_begin_export(slot_idx int) int
fn C.duckdb_mcp_end_export(slot_idx int) int
fn C.duckdb_mcp_signal_error(slot_idx int) int
fn C.duckdb_mcp_query_count(slot_idx int) int
fn C.duckdb_mcp_export_count(slot_idx int) int
fn C.duckdb_mcp_action_requires_open(action int) int
fn C.duckdb_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 ABI exactly)
// ---------------------------------------------------------------------------

enum ConnState {
	closed        = 0
	open          = 1
	query_running = 2
	exporting     = 3
	err           = 4
}

fn state_label(s int) string {
	return match s {
		0 { 'closed' }
		1 { 'open' }
		2 { 'query_running' }
		3 { 'exporting' }
		4 { 'error' }
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
	from    int
	to      int
	valid   bool
}

struct QueryCountResponse {
	slot  int
	count int
}

struct ExportCountResponse {
	slot  int
	count int
}

// ---------------------------------------------------------------------------
// Adapter functions (embedded bridge)
// ---------------------------------------------------------------------------

pub fn session_open() !SessionResponse {
	slot := C.duckdb_mcp_session_open()
	if slot < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		slot: slot
		state: 'open'
	}
}

pub fn session_close(slot int) !string {
	result := C.duckdb_mcp_session_close(slot)
	return match result {
		0 { 'closed slot ${slot}' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.duckdb_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn begin_query(slot int) !string {
	result := C.duckdb_mcp_begin_query(slot)
	return match result {
		0 { 'query running on slot ${slot}' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn end_query(slot int) !string {
	result := C.duckdb_mcp_end_query(slot)
	return match result {
		0 { 'query completed on slot ${slot}' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn begin_export(slot int) !string {
	result := C.duckdb_mcp_begin_export(slot)
	return match result {
		0 { 'export running on slot ${slot}' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn end_export(slot int) !string {
	result := C.duckdb_mcp_end_export(slot)
	return match result {
		0 { 'export completed on slot ${slot}' }
		-1 { return error('slot ${slot} not valid') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error') }
	}
}

pub fn query_count(slot int) QueryCountResponse {
	count := C.duckdb_mcp_query_count(slot)
	return QueryCountResponse{ slot: slot, count: count }
}

pub fn export_count(slot int) ExportCountResponse {
	count := C.duckdb_mcp_export_count(slot)
	return ExportCountResponse{ slot: slot, count: count }
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.duckdb_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.duckdb_mcp_reset()
}
