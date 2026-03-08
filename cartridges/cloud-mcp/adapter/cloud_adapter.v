// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Cloud-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (cloud_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides provider session lifecycle management, operation execution,
// and state machine inspection via the BoJ triple adapter.

module cloud_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against cloud_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.cloud_authenticate(provider int) int
fn C.cloud_logout(slot_idx int) int
fn C.cloud_begin_operation(slot_idx int) int
fn C.cloud_end_operation(slot_idx int) int
fn C.cloud_state(slot_idx int) int
fn C.cloud_can_transition(from int, to int) int
fn C.cloud_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum SessionState {
	unauthenticated = 0
	authenticated = 1
	operating = 2
	auth_error = 3
}

enum CloudProvider {
	aws = 1
	gcloud = 2
	azure = 3
	digital_ocean = 4
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'auth_error' }
		else { 'unknown' }
	}
}

fn provider_label(p CloudProvider) string {
	return match p {
		.aws { 'AWS' }
		.gcloud { 'GCloud' }
		.azure { 'Azure' }
		.digital_ocean { 'DigitalOcean' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct AuthResponse {
	slot     int
	provider string
	state    string
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

pub fn authenticate(provider_name string) !AuthResponse {
	p := match provider_name {
		'aws' { int(CloudProvider.aws) }
		'gcloud' { int(CloudProvider.gcloud) }
		'azure' { int(CloudProvider.azure) }
		'digitalocean' { int(CloudProvider.digital_ocean) }
		else { return error('unknown provider: ${provider_name}') }
	}
	slot := C.cloud_authenticate(p)
	if slot < 0 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		provider: provider_name
		state: 'authenticated'
	}
}

pub fn logout(slot int) !string {
	result := C.cloud_logout(slot)
	return match result {
		0 { 'logged out slot ${slot}' }
		-1 { return error('slot ${slot} not active or already unauthenticated') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.cloud_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn begin_operation(slot int) !string {
	result := C.cloud_begin_operation(slot)
	return match result {
		0 { 'operation started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot begin operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_operation(slot int) !string {
	result := C.cloud_end_operation(slot)
	return match result {
		0 { 'operation completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.cloud_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.cloud_reset()
}
