// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// SSG-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (ssg_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides build pipeline enforcement, preview-before-deploy safety,
// and state machine inspection via the BoJ triple adapter.

module ssg_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against ssg_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.ssg_load_content(engine int, content_hash u32) int
fn C.ssg_build(slot_idx int) int
fn C.ssg_preview(slot_idx int) int
fn C.ssg_ready_deploy(slot_idx int) int
fn C.ssg_deploy(slot_idx int) int
fn C.ssg_clean(slot_idx int) int
fn C.ssg_state(slot_idx int) int
fn C.ssg_can_transition(from int, to int) int
fn C.ssg_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum SsgState {
	empty = 0
	content_loaded = 1
	built = 2
	previewing = 3
	ready_to_deploy = 4
	deployed = 5
	ssg_error = 6
}

enum SsgEngine {
	hugo = 1
	zola = 2
	astro = 3
	casket = 4
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'empty' }
		1 { 'content_loaded' }
		2 { 'built' }
		3 { 'previewing' }
		4 { 'ready_to_deploy' }
		5 { 'deployed' }
		6 { 'error' }
		else { 'unknown' }
	}
}

fn engine_label(e SsgEngine) string {
	return match e {
		.hugo { 'Hugo' }
		.zola { 'Zola' }
		.astro { 'Astro' }
		.casket { 'Casket' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct LoadResponse {
	slot   int
	engine string
	state  string
}

struct BuildResponse {
	slot  int
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

pub fn load_content(engine_name string, content_hash u32) !LoadResponse {
	e := match engine_name {
		'hugo' { int(SsgEngine.hugo) }
		'zola' { int(SsgEngine.zola) }
		'astro' { int(SsgEngine.astro) }
		'casket' { int(SsgEngine.casket) }
		else { return error('unknown SSG engine: ${engine_name}') }
	}
	slot := C.ssg_load_content(e, content_hash)
	if slot < 0 {
		return error('no site slots available')
	}
	return LoadResponse{
		slot: slot
		engine: engine_name
		state: 'content_loaded'
	}
}

pub fn build_site(slot int) !BuildResponse {
	result := C.ssg_build(slot)
	return match result {
		0 {
			BuildResponse{
				slot: slot
				state: 'built'
			}
		}
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot build from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn preview(slot int) !string {
	result := C.ssg_preview(slot)
	return match result {
		0 { 'preview started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot preview: site must be built first') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn ready_deploy(slot int) !string {
	result := C.ssg_ready_deploy(slot)
	return match result {
		0 { 'slot ${slot} ready to deploy' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot mark ready: must be previewing') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn deploy(slot int) !string {
	result := C.ssg_deploy(slot)
	return match result {
		0 { 'deployed site on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot deploy: must preview first (build -> preview -> deploy)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn clean(slot int) !string {
	result := C.ssg_clean(slot)
	return match result {
		0 { 'cleaned slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot clean from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.ssg_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.ssg_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.ssg_reset()
}
