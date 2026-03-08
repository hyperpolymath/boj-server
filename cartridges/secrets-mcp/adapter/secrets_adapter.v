// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Secrets-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (secrets_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides vault seal/unseal lifecycle, secret access with audit trail,
// and state machine inspection via the BoJ triple adapter.

module secrets_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against secrets_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.sec_unseal(backend int) int
fn C.sec_authenticate(slot_idx int) int
fn C.sec_begin_access(slot_idx int) int
fn C.sec_end_access(slot_idx int) int
fn C.sec_seal(slot_idx int) int
fn C.sec_state(slot_idx int) int
fn C.sec_access_count(slot_idx int) int
fn C.sec_can_transition(from int, to int) int
fn C.sec_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum VaultState {
	sealed = 0
	unsealed = 1
	authenticated = 2
	accessing = 3
	secret_error = 4
}

enum SecretBackend {
	vault = 1
	sops = 2
	env_vault = 3
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'sealed' }
		1 { 'unsealed' }
		2 { 'authenticated' }
		3 { 'accessing' }
		4 { 'secret_error' }
		else { 'unknown' }
	}
}

fn backend_label(b SecretBackend) string {
	return match b {
		.vault { 'Vault' }
		.sops { 'SOPS' }
		.env_vault { 'EnvVault' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct UnsealResponse {
	slot    int
	backend string
	state   string
}

struct StateResponse {
	slot         int
	state        string
	access_count int
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

pub fn unseal(backend_name string) !UnsealResponse {
	b := match backend_name {
		'vault' { int(SecretBackend.vault) }
		'sops' { int(SecretBackend.sops) }
		'env_vault' { int(SecretBackend.env_vault) }
		else { return error('unknown backend: ${backend_name}') }
	}
	slot := C.sec_unseal(b)
	if slot < 0 {
		return error('no vault slots available')
	}
	return UnsealResponse{
		slot: slot
		backend: backend_name
		state: 'unsealed'
	}
}

pub fn authenticate(slot int) !string {
	result := C.sec_authenticate(slot)
	return match result {
		0 { 'authenticated vault slot ${slot}' }
		-1 { return error('slot ${slot} not active or not unsealed') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn begin_access(slot int) !string {
	result := C.sec_begin_access(slot)
	return match result {
		0 { 'access started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot access from current state (authenticated?)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_access(slot int) !string {
	result := C.sec_end_access(slot)
	return match result {
		0 { 'access completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end access from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn seal(slot int) !string {
	result := C.sec_seal(slot)
	return match result {
		0 { 'sealed vault slot ${slot}' }
		-1 { return error('slot ${slot} not active or already sealed') }
		-2 { return error('invalid state transition (deauth first)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.sec_state(slot)
	ac := C.sec_access_count(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
		access_count: ac
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.sec_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.sec_reset()
}
