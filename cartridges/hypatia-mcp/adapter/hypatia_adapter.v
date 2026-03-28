// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Hypatia V-lang adapter — bridges Zig FFI to REST endpoints.

module hypatia_adapter

fn C.hypatia_scan_repo(path &u8) u32
fn C.hypatia_train_model(model_name &u8) int
fn C.hypatia_get_score(scan_id u32) u8
fn C.hypatia_get_rule_count() u32

struct Response {
	ok   bool
	data string
}

pub fn handle_scan_repo(path string) Response {
	scan_id := C.hypatia_scan_repo(path.str)
	if scan_id == 0 {
		return Response{ ok: false, data: 'invalid path' }
	}
	return Response{ ok: true, data: '${scan_id}' }
}

pub fn handle_train_model(model_name string) Response {
	rc := C.hypatia_train_model(model_name.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'training started' } else { 'error' } }
}

pub fn handle_get_score(scan_id u32) Response {
	score := C.hypatia_get_score(scan_id)
	return Response{ ok: true, data: '${score}' }
}

pub fn handle_get_rule_set() Response {
	count := C.hypatia_get_rule_count()
	return Response{ ok: true, data: '${count} rules active' }
}
