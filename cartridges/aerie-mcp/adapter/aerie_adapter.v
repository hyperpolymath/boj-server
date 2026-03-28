// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Aerie V-lang adapter — bridges Zig FFI to REST endpoints.

module aerie_adapter

fn C.aerie_list_envs_count() u32
fn C.aerie_create_env(name &u8, mem_mb u32) u32
fn C.aerie_destroy_env(env_id u32) int
fn C.aerie_get_status(env_id u32) u8

struct Response {
	ok   bool
	data string
}

pub fn handle_list_envs() Response {
	count := C.aerie_list_envs_count()
	return Response{ ok: true, data: '${count} environments' }
}

pub fn handle_create_env(name string, mem_mb u32) Response {
	env_id := C.aerie_create_env(name.str, mem_mb)
	if env_id == 0 {
		return Response{ ok: false, data: 'creation failed' }
	}
	return Response{ ok: true, data: '${env_id}' }
}

pub fn handle_destroy_env(env_id u32) Response {
	rc := C.aerie_destroy_env(env_id)
	return Response{ ok: rc == 0, data: if rc == 0 { 'destroyed' } else { 'error' } }
}

pub fn handle_get_status(env_id u32) Response {
	s := C.aerie_get_status(env_id)
	labels := ['provisioning', 'ready', 'destroying', 'destroyed', 'error']
	label := if s < labels.len { labels[s] } else { 'unknown' }
	return Response{ ok: true, data: label }
}
