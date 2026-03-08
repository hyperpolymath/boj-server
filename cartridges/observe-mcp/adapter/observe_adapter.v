// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Observe-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (observe_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides source registration, query lifecycle management, backpressure
// tracking, and state machine inspection via the BoJ triple adapter.

module observe_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against observe_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.obs_register(backend int) int
fn C.obs_begin_query(slot_idx int) int
fn C.obs_end_query(slot_idx int) int
fn C.obs_unregister(slot_idx int) int
fn C.obs_state(slot_idx int) int
fn C.obs_query_count(slot_idx int) int
fn C.obs_can_transition(from int, to int) int
fn C.obs_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum ObserveState {
	unconfigured = 0
	source_registered = 1
	query_ready = 2
	querying = 3
	observe_error = 4
}

enum ObserveBackend {
	prometheus = 1
	grafana = 2
	loki = 3
	jaeger = 4
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'unconfigured' }
		1 { 'source_registered' }
		2 { 'query_ready' }
		3 { 'querying' }
		4 { 'error' }
		else { 'unknown' }
	}
}

fn backend_label(b ObserveBackend) string {
	return match b {
		.prometheus { 'Prometheus' }
		.grafana { 'Grafana' }
		.loki { 'Loki' }
		.jaeger { 'Jaeger' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct RegisterResponse {
	slot    int
	backend string
	state   string
}

struct StateResponse {
	slot        int
	state       string
	query_count int
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

pub fn register_source(backend_name string) !RegisterResponse {
	b := match backend_name {
		'prometheus' { int(ObserveBackend.prometheus) }
		'grafana' { int(ObserveBackend.grafana) }
		'loki' { int(ObserveBackend.loki) }
		'jaeger' { int(ObserveBackend.jaeger) }
		else { return error('unknown backend: ${backend_name}') }
	}
	slot := C.obs_register(b)
	if slot < 0 {
		return error('no source slots available')
	}
	return RegisterResponse{
		slot: slot
		backend: backend_name
		state: 'source_registered'
	}
}

pub fn begin_query(slot int) !string {
	result := C.obs_begin_query(slot)
	return match result {
		0 { 'query started on slot ${slot}' }
		-1 { return error('slot ${slot} not active or unconfigured') }
		-2 { return error('cannot query: source not in query-ready state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_query(slot int) !string {
	result := C.obs_end_query(slot)
	return match result {
		0 { 'query completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end query from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn unregister(slot int) !string {
	result := C.obs_unregister(slot)
	return match result {
		0 { 'unregistered source on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot unregister: source must be in query_ready state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.obs_state(slot)
	qc := C.obs_query_count(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
		query_count: qc
	}
}

pub fn query_count(slot int) int {
	return C.obs_query_count(slot)
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.obs_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.obs_reset()
}
