// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// TypedWasm V-lang adapter — bridges Zig FFI to REST endpoints.

module typed_wasm_adapter

fn C.typed_wasm_validate_module(module_path &u8) u8
fn C.typed_wasm_check_types(module_path &u8) u32
fn C.typed_wasm_compile_module(module_path &u8, target u8) int

struct Response {
	ok   bool
	data string
}

pub fn handle_validate_module(module_path string) Response {
	level := C.typed_wasm_validate_module(module_path.str)
	if level == 255 {
		return Response{ ok: false, data: 'validation error' }
	}
	return Response{ ok: true, data: 'safety level ${level}/10' }
}

pub fn handle_check_types(module_path string) Response {
	errors := C.typed_wasm_check_types(module_path.str)
	return Response{ ok: errors == 0, data: '${errors} type errors' }
}

pub fn handle_compile_module(module_path string, target u8) Response {
	rc := C.typed_wasm_compile_module(module_path.str, target)
	return Response{ ok: rc == 0, data: if rc == 0 { 'compiled' } else { 'compile failed' } }
}
