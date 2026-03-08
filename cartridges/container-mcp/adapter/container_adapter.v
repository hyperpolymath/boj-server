// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Container-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (container_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides container lifecycle management and state machine inspection
// via the BoJ triple adapter.

module container_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against container_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.ctr_build(runtime int, image_name &u8) int
fn C.ctr_create(slot_idx int) int
fn C.ctr_start(slot_idx int) int
fn C.ctr_stop(slot_idx int) int
fn C.ctr_remove(slot_idx int) int
fn C.ctr_state(slot_idx int) int
fn C.ctr_can_transition(from int, to int) int
fn C.ctr_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum CtrState {
	none = 0
	built = 1
	created = 2
	running = 3
	stopped = 4
	removed = 5
}

enum ContainerRuntime {
	podman = 1
	nerdctl = 2
	docker = 3
}

fn state_label(s int) string {
	return match s {
		0 { 'none' }
		1 { 'built' }
		2 { 'created' }
		3 { 'running' }
		4 { 'stopped' }
		5 { 'removed' }
		else { 'unknown' }
	}
}

fn runtime_label(r ContainerRuntime) string {
	return match r {
		.podman { 'Podman' }
		.nerdctl { 'Nerdctl' }
		.docker { 'Docker' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct BuildResponse {
	slot    int
	runtime string
	image   string
	state   string
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

pub fn build_image(runtime_name string, image_name string) !BuildResponse {
	r := match runtime_name {
		'podman' { int(ContainerRuntime.podman) }
		'nerdctl' { int(ContainerRuntime.nerdctl) }
		'docker' { int(ContainerRuntime.docker) }
		else { return error('unknown runtime: ${runtime_name}') }
	}
	slot := C.ctr_build(r, image_name.str)
	if slot < 0 {
		return error('no container slots available')
	}
	return BuildResponse{
		slot: slot
		runtime: runtime_name
		image: image_name
		state: 'built'
	}
}

pub fn create(slot int) !string {
	result := C.ctr_create(slot)
	return match result {
		0 { 'container created at slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot create from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn start(slot int) !string {
	result := C.ctr_start(slot)
	return match result {
		0 { 'container started at slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot start from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn stop(slot int) !string {
	result := C.ctr_stop(slot)
	return match result {
		0 { 'container stopped at slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot stop from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn remove(slot int) !string {
	result := C.ctr_remove(slot)
	return match result {
		0 { 'container removed at slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot remove from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.ctr_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.ctr_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.ctr_reset()
}
