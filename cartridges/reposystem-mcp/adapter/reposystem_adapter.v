// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Reposystem V-lang adapter — bridges Zig FFI to REST endpoints.

module reposystem_adapter

fn C.reposystem_list_repos_count() u32
fn C.reposystem_check_health(repo_name &u8) u8
fn C.reposystem_sync_mirrors(repo_name &u8) int
fn C.reposystem_run_audit(repo_name &u8) u32

struct Response {
	ok   bool
	data string
}

pub fn handle_list_repos() Response {
	count := C.reposystem_list_repos_count()
	return Response{ ok: true, data: '${count} repos' }
}

pub fn handle_check_health(repo_name string) Response {
	h := C.reposystem_check_health(repo_name.str)
	labels := ['green', 'yellow', 'red', 'unknown']
	label := if h < labels.len { labels[h] } else { 'unknown' }
	return Response{ ok: true, data: label }
}

pub fn handle_sync_mirrors(repo_name string) Response {
	rc := C.reposystem_sync_mirrors(repo_name.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'synced' } else { 'sync failed' } }
}

pub fn handle_run_audit(repo_name string) Response {
	passed := C.reposystem_run_audit(repo_name.str)
	return Response{ ok: true, data: '${passed} checks passed' }
}
