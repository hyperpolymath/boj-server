// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Laminar V-lang adapter — bridges Zig FFI to REST endpoints.

module laminar_adapter

fn C.laminar_create_pipeline(name &u8) u32
fn C.laminar_run_stage(pipeline_id u32, stage_name &u8) int
fn C.laminar_get_status(pipeline_id u32) u8
fn C.laminar_cancel_pipeline(pipeline_id u32) int

struct Response {
	ok   bool
	data string
}

pub fn handle_create_pipeline(name string) Response {
	pid := C.laminar_create_pipeline(name.str)
	if pid == 0 {
		return Response{ ok: false, data: 'creation failed' }
	}
	return Response{ ok: true, data: '${pid}' }
}

pub fn handle_run_stage(pipeline_id u32, stage_name string) Response {
	rc := C.laminar_run_stage(pipeline_id, stage_name.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'stage started' } else { 'error' } }
}

pub fn handle_get_status(pipeline_id u32) Response {
	s := C.laminar_get_status(pipeline_id)
	labels := ['pending', 'running', 'succeeded', 'failed', 'cancelled']
	label := if s < labels.len { labels[s] } else { 'unknown' }
	return Response{ ok: true, data: label }
}

pub fn handle_cancel_pipeline(pipeline_id u32) Response {
	rc := C.laminar_cancel_pipeline(pipeline_id)
	return Response{ ok: rc == 0, data: if rc == 0 { 'cancelled' } else { 'error' } }
}
