// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Database-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (database_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides connection lifecycle management, query execution, and state
// machine inspection via the BoJ triple adapter.

module database_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against database_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.db_connect(backend int) int
fn C.db_disconnect(slot_idx int) int
fn C.db_state(slot_idx int) int
fn C.db_begin_query(slot_idx int) int
fn C.db_end_query(slot_idx int) int
fn C.db_query_error(slot_idx int) int
fn C.db_can_transition(from int, to int) int
fn C.db_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum ConnState {
	disconnected = 0
	connected = 1
	querying = 2
	err = 3
}

enum DatabaseBackend {
	verisimdb = 1
	postgresql = 2
	sqlite = 3
	redis = 4
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'connected' }
		2 { 'querying' }
		3 { 'error' }
		else { 'unknown' }
	}
}

fn backend_label(b DatabaseBackend) string {
	return match b {
		.verisimdb { 'VeriSimDB' }
		.postgresql { 'PostgreSQL' }
		.sqlite { 'SQLite' }
		.redis { 'Redis' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct ConnectResponse {
	slot    int
	backend string
	state   string
}

struct StateResponse {
	slot  int
	state string
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

pub fn connect(backend_name string) !ConnectResponse {
	b := match backend_name {
		'verisimdb' { int(DatabaseBackend.verisimdb) }
		'postgresql' { int(DatabaseBackend.postgresql) }
		'sqlite' { int(DatabaseBackend.sqlite) }
		'redis' { int(DatabaseBackend.redis) }
		else { return error('unknown backend: ${backend_name}') }
	}
	slot := C.db_connect(b)
	if slot < 0 {
		return error('no connection slots available')
	}
	return ConnectResponse{
		slot: slot
		backend: backend_name
		state: 'connected'
	}
}

pub fn disconnect(slot int) !string {
	result := C.db_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active or already disconnected') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.db_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn begin_query(slot int) !string {
	result := C.db_begin_query(slot)
	return match result {
		0 { 'query started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot begin query from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_query(slot int) !string {
	result := C.db_end_query(slot)
	return match result {
		0 { 'query completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end query from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.db_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.db_reset()
}
