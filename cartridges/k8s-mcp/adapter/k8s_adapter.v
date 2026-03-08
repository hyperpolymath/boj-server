// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// K8s-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (k8s_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides cluster connection lifecycle, namespace management, and
// state machine inspection via the BoJ triple adapter.

module k8s_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against k8s_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.k8s_connect(tool int) int
fn C.k8s_select_namespace(slot_idx int, ns &u8) int
fn C.k8s_begin_operation(slot_idx int) int
fn C.k8s_end_operation(slot_idx int) int
fn C.k8s_disconnect(slot_idx int) int
fn C.k8s_state(slot_idx int) int
fn C.k8s_can_transition(from int, to int) int
fn C.k8s_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum K8sState {
	disconnected = 0
	cluster_connected = 1
	namespace_selected = 2
	operating = 3
	k8s_error = 4
}

enum K8sTool {
	kubectl = 1
	helm = 2
	kustomize = 3
}

fn state_label(s int) string {
	return match s {
		0 { 'disconnected' }
		1 { 'cluster_connected' }
		2 { 'namespace_selected' }
		3 { 'operating' }
		4 { 'k8s_error' }
		else { 'unknown' }
	}
}

fn tool_label(t K8sTool) string {
	return match t {
		.kubectl { 'kubectl' }
		.helm { 'helm' }
		.kustomize { 'kustomize' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct ConnectResponse {
	slot  int
	tool  string
	state string
}

struct NamespaceResponse {
	slot      int
	namespace string
	state     string
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

pub fn connect(tool_name string) !ConnectResponse {
	t := match tool_name {
		'kubectl' { int(K8sTool.kubectl) }
		'helm' { int(K8sTool.helm) }
		'kustomize' { int(K8sTool.kustomize) }
		else { return error('unknown tool: ${tool_name}') }
	}
	slot := C.k8s_connect(t)
	if slot < 0 {
		return error('no cluster slots available')
	}
	return ConnectResponse{
		slot: slot
		tool: tool_name
		state: 'cluster_connected'
	}
}

pub fn select_namespace(slot int, ns string) !NamespaceResponse {
	result := C.k8s_select_namespace(slot, ns.str)
	return match result {
		0 {
			NamespaceResponse{
				slot: slot
				namespace: ns
				state: 'namespace_selected'
			}
		}
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot select namespace from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn begin_operation(slot int) !string {
	result := C.k8s_begin_operation(slot)
	return match result {
		0 { 'operation started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot begin operation — namespace not selected') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_operation(slot int) !string {
	result := C.k8s_end_operation(slot)
	return match result {
		0 { 'operation completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn disconnect(slot int) !string {
	result := C.k8s_disconnect(slot)
	return match result {
		0 { 'disconnected slot ${slot}' }
		-1 { return error('slot ${slot} not active or already disconnected') }
		-2 { return error('invalid state transition — deselect namespace first') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.k8s_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.k8s_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.k8s_reset()
}
