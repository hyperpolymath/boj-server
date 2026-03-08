// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Git-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (git_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides forge authentication, repository selection, and operation
// lifecycle management via the BoJ triple adapter.

module git_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against git_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.git_authenticate(forge_type int) int
fn C.git_select_repo(slot_idx int, owner &u8, name &u8) int
fn C.git_begin_operation(slot_idx int) int
fn C.git_end_operation(slot_idx int) int
fn C.git_logout(slot_idx int) int
fn C.git_state(slot_idx int) int
fn C.git_can_transition(from int, to int) int
fn C.git_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum GitState {
	unauthenticated = 0
	authenticated = 1
	repo_selected = 2
	operating = 3
	git_error = 4
}

enum GitForge {
	github = 1
	gitlab = 2
	gitea = 3
	bitbucket = 4
}

fn state_label(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'repo_selected' }
		3 { 'operating' }
		4 { 'git_error' }
		else { 'unknown' }
	}
}

fn forge_label(f GitForge) string {
	return match f {
		.github { 'GitHub' }
		.gitlab { 'GitLab' }
		.gitea { 'Gitea' }
		.bitbucket { 'Bitbucket' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct AuthResponse {
	slot  int
	forge string
	state string
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

pub fn authenticate(forge_name string) !AuthResponse {
	f := match forge_name {
		'github' { int(GitForge.github) }
		'gitlab' { int(GitForge.gitlab) }
		'gitea' { int(GitForge.gitea) }
		'bitbucket' { int(GitForge.bitbucket) }
		else { return error('unknown forge: ${forge_name}') }
	}
	slot := C.git_authenticate(f)
	if slot < 0 {
		return error('no forge slots available')
	}
	return AuthResponse{
		slot: slot
		forge: forge_name
		state: 'authenticated'
	}
}

pub fn select_repo(slot int, owner string, name string) !string {
	result := C.git_select_repo(slot, owner.str, name.str)
	return match result {
		0 { 'selected ${owner}/${name} on slot ${slot}' }
		-1 { return error('slot ${slot} not active or not authenticated') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn begin_operation(slot int) !string {
	result := C.git_begin_operation(slot)
	return match result {
		0 { 'operation started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot begin operation from current state (repo selected?)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_operation(slot int) !string {
	result := C.git_end_operation(slot)
	return match result {
		0 { 'operation completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn logout(slot int) !string {
	result := C.git_logout(slot)
	return match result {
		0 { 'logged out from slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition (deselect repo first)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.git_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.git_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.git_reset()
}
