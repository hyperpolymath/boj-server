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
fn C.db_connect_sqlite(path_ptr &u8, path_len usize) int
fn C.db_disconnect(slot_idx int) int
fn C.db_state(slot_idx int) int
fn C.db_begin_query(slot_idx int) int
fn C.db_end_query(slot_idx int) int
fn C.db_query_error(slot_idx int) int
fn C.db_can_transition(from int, to int) int
fn C.db_execute_sql(slot u8, sql_ptr &u8, sql_len usize, out_ptr &u8, out_len usize) int
fn C.db_connect_verisimdb(url_ptr &u8, url_len usize) int
fn C.db_execute_vql(slot u8, vql_ptr &u8, vql_len usize, out_ptr &u8, out_len usize) int
fn C.db_connect_quandledb(url_ptr &u8, url_len usize) int
fn C.db_execute_kql(slot u8, kql_ptr &u8, kql_len usize, out_ptr &u8, out_len usize) int
fn C.db_connect_lithoglyph(url_ptr &u8, url_len usize) int
fn C.db_execute_gql(slot u8, gql_ptr &u8, gql_len usize, out_ptr &u8, out_len usize) int
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
	quandledb = 5
	lithoglyph = 6
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
		.quandledb { 'QuandleDB' }
		.lithoglyph { 'LithoGlyph' }
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
		'quandledb' { int(DatabaseBackend.quandledb) }
		'lithoglyph' { int(DatabaseBackend.lithoglyph) }
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

pub fn connect_sqlite(path string) !ConnectResponse {
	slot := C.db_connect_sqlite(path.str, usize(path.len))
	if slot < 0 {
		return match slot {
			-1 { error('no connection slots available') }
			-3 { error('sqlite3_open failed for path: ${path}') }
			else { error('unknown error (code ${slot})') }
		}
	}
	return ConnectResponse{
		slot: slot
		backend: 'sqlite'
		state: 'connected'
	}
}

pub fn execute_sql(slot int, sql string) !string {
	if slot < 0 || slot > 255 {
		return error('invalid slot index: ${slot}')
	}
	mut out_buf := []u8{len: 65536}
	result := C.db_execute_sql(u8(slot), sql.str, usize(sql.len), out_buf.data, usize(out_buf.len))
	if result < 0 {
		return match result {
			-1 { error('invalid or inactive slot') }
			-2 { error('connection not in queryable state') }
			-3 { error('slot does not have a sqlite handle (wrong backend?)') }
			-4 { error('sqlite3_exec failed') }
			-5 { error('output buffer too small') }
			else { error('unknown error (code ${result})') }
		}
	}
	return out_buf[..result].bytestr()
}

pub fn connect_verisimdb(url string) !ConnectResponse {
	slot := C.db_connect_verisimdb(url.str, usize(url.len))
	if slot < 0 {
		return match slot {
			-1 { error('no connection slots available') }
			-6 { error('URL empty or too long (max ${512} bytes): ${url}') }
			else { error('unknown error (code ${slot})') }
		}
	}
	return ConnectResponse{
		slot: slot
		backend: 'verisimdb'
		state: 'connected'
	}
}

pub fn execute_vql(slot int, vql string) !string {
	if slot < 0 || slot > 255 {
		return error('invalid slot index: ${slot}')
	}
	mut out_buf := []u8{len: 65536}
	result := C.db_execute_vql(u8(slot), vql.str, usize(vql.len), out_buf.data, usize(out_buf.len))
	if result < 0 {
		return match result {
			-1 { error('invalid or inactive slot') }
			-2 { error('connection not in queryable state') }
			-5 { error('output buffer too small') }
			-6 { error('slot does not have a VeriSimDB URL (wrong backend?)') }
			-7 { error('VQL execution failed (curl returned non-zero)') }
			else { error('unknown error (code ${result})') }
		}
	}
	return out_buf[..result].bytestr()
}

pub fn connect_quandledb(url string) !ConnectResponse {
	slot := C.db_connect_quandledb(url.str, usize(url.len))
	if slot < 0 {
		return match slot {
			-1 { error('no connection slots available') }
			-6 { error('URL empty or too long (max ${512} bytes): ${url}') }
			else { error('unknown error (code ${slot})') }
		}
	}
	return ConnectResponse{
		slot: slot
		backend: 'quandledb'
		state: 'connected'
	}
}

pub fn execute_kql(slot int, kql string) !string {
	if slot < 0 || slot > 255 {
		return error('invalid slot index: ${slot}')
	}
	mut out_buf := []u8{len: 65536}
	result := C.db_execute_kql(u8(slot), kql.str, usize(kql.len), out_buf.data, usize(out_buf.len))
	if result < 0 {
		return match result {
			-1 { error('invalid or inactive slot') }
			-2 { error('connection not in queryable state') }
			-5 { error('output buffer too small') }
			-6 { error('slot does not have a QuandleDB URL (wrong backend?)') }
			-7 { error('KQL execution failed (curl returned non-zero)') }
			else { error('unknown error (code ${result})') }
		}
	}
	return out_buf[..result].bytestr()
}

pub fn connect_lithoglyph(url string) !ConnectResponse {
	slot := C.db_connect_lithoglyph(url.str, usize(url.len))
	if slot < 0 {
		return match slot {
			-1 { error('no connection slots available') }
			-6 { error('URL empty or too long (max ${512} bytes): ${url}') }
			else { error('unknown error (code ${slot})') }
		}
	}
	return ConnectResponse{
		slot: slot
		backend: 'lithoglyph'
		state: 'connected'
	}
}

pub fn execute_gql(slot int, gql string) !string {
	if slot < 0 || slot > 255 {
		return error('invalid slot index: ${slot}')
	}
	mut out_buf := []u8{len: 65536}
	result := C.db_execute_gql(u8(slot), gql.str, usize(gql.len), out_buf.data, usize(out_buf.len))
	if result < 0 {
		return match result {
			-1 { error('invalid or inactive slot') }
			-2 { error('connection not in queryable state') }
			-5 { error('output buffer too small') }
			-6 { error('slot does not have a LithoGlyph URL (wrong backend?)') }
			-7 { error('GQL execution failed (curl returned non-zero)') }
			else { error('unknown error (code ${result})') }
		}
	}
	return out_buf[..result].bytestr()
}

pub fn reset() {
	C.db_reset()
}
