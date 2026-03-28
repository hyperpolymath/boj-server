// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// VeriSimDB V-lang adapter — bridges Zig FFI to REST endpoints.

module verisimdb_adapter

fn C.verisimdb_store_octad(key &u8, data &u8) int
fn C.verisimdb_get_octad(key &u8) int
fn C.verisimdb_detect_drift(key &u8) u32
fn C.verisimdb_query_audit(from_ts u64, to_ts u64) u32

struct Response {
	ok   bool
	data string
}

pub fn handle_store_octad(key string, data string) Response {
	rc := C.verisimdb_store_octad(key.str, data.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'stored' } else { 'store failed' } }
}

pub fn handle_get_octad(key string) Response {
	rc := C.verisimdb_get_octad(key.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'found' } else { 'not found' } }
}

pub fn handle_detect_drift(key string) Response {
	count := C.verisimdb_detect_drift(key.str)
	return Response{ ok: true, data: '${count} drifted fields' }
}

pub fn handle_query_audit(from_ts u64, to_ts u64) Response {
	count := C.verisimdb_query_audit(from_ts, to_ts)
	return Response{ ok: true, data: '${count} entries' }
}
