// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Stapeln V-lang adapter — bridges Zig FFI to REST endpoints.

module stapeln_adapter

fn C.stapeln_list_stacks_count() u32
fn C.stapeln_deploy(name &u8, replicas u32) int
fn C.stapeln_scale(name &u8, replicas u32) int
fn C.stapeln_get_health(name &u8) u8

struct Response {
	ok   bool
	data string
}

pub fn handle_list_stacks() Response {
	count := C.stapeln_list_stacks_count()
	return Response{ ok: true, data: '${count} stacks' }
}

pub fn handle_deploy(name string, replicas u32) Response {
	rc := C.stapeln_deploy(name.str, replicas)
	return Response{ ok: rc == 0, data: if rc == 0 { 'deployed' } else { 'deploy failed' } }
}

pub fn handle_scale(name string, replicas u32) Response {
	rc := C.stapeln_scale(name.str, replicas)
	return Response{ ok: rc == 0, data: if rc == 0 { 'scaled to ${replicas}' } else { 'scale failed' } }
}

pub fn handle_get_health(name string) Response {
	h := C.stapeln_get_health(name.str)
	labels := ['healthy', 'degraded', 'unhealthy', 'unknown']
	label := if h < labels.len { labels[h] } else { 'unknown' }
	return Response{ ok: true, data: label }
}
