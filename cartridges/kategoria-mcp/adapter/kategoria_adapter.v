// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Kategoria V-lang adapter — bridges Zig FFI to REST endpoints.

module kategoria_adapter

fn C.kategoria_classify(input &u8) u8
fn C.kategoria_get_routes(label &u8) u32
fn C.kategoria_get_levels() u32
fn C.kategoria_eval_challenge(level u8, input &u8) u8

struct Response {
	ok   bool
	data string
}

pub fn handle_classify(input string) Response {
	conf := C.kategoria_classify(input.str)
	if conf == 255 {
		return Response{ ok: false, data: 'classification error' }
	}
	return Response{ ok: true, data: 'confidence ${conf}%' }
}

pub fn handle_get_routes(label string) Response {
	count := C.kategoria_get_routes(label.str)
	return Response{ ok: true, data: '${count} routes' }
}

pub fn handle_get_levels() Response {
	levels := C.kategoria_get_levels()
	return Response{ ok: true, data: '${levels} taxonomy levels' }
}

pub fn handle_eval_challenge(level u8, input string) Response {
	score := C.kategoria_eval_challenge(level, input.str)
	return Response{ ok: score > 0, data: 'score ${score}/100' }
}
