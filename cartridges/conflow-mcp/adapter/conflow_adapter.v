// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Conflow V-lang adapter — bridges Zig FFI to REST endpoints.

module conflow_adapter

fn C.conflow_get_config(key &u8) int
fn C.conflow_apply_config(blob &u8) int
fn C.conflow_validate_config(blob &u8) int
fn C.conflow_diff_config(a &u8, b &u8) u32

struct Response {
	ok   bool
	data string
}

pub fn handle_get_config(key string) Response {
	rc := C.conflow_get_config(key.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'found' } else { 'not found' } }
}

pub fn handle_apply_config(blob string) Response {
	rc := C.conflow_apply_config(blob.str)
	if rc < 0 {
		return Response{ ok: false, data: 'apply failed' }
	}
	return Response{ ok: true, data: '${rc} entries applied' }
}

pub fn handle_validate_config(blob string) Response {
	rc := C.conflow_validate_config(blob.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'valid' } else { '${rc} errors' } }
}

pub fn handle_diff_config(a string, b string) Response {
	count := C.conflow_diff_config(a.str, b.str)
	return Response{ ok: true, data: '${count} differences' }
}
