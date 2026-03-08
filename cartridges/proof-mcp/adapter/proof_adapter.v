// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Proof-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (proof_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides proof verification lifecycle management, backend selection,
// and state machine inspection via the BoJ triple adapter.
//
// Ports: REST 9013, gRPC-Web 9014, GraphQL 9015

module proof_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against proof_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.proof_init(backend int) int
fn C.proof_load(slot_idx int, backend int) int
fn C.proof_verify(slot_idx int) int
fn C.proof_succeed(slot_idx int) int
fn C.proof_fail(slot_idx int) int
fn C.proof_get_result(slot_idx int) int
fn C.proof_reset(slot_idx int) int
fn C.proof_state(slot_idx int) int
fn C.proof_can_transition(from int, to int) int
fn C.proof_release(slot_idx int) int
fn C.proof_reset_all()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum ProofState {
	idle = 0
	loading = 1
	verifying = 2
	verified = 3
	failed = 4
}

enum ProofBackend {
	z3 = 1
	cvc5 = 2
	lean = 3
	coq = 4
	agda = 5
	isabelle = 6
	idris2 = 7
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'idle' }
		1 { 'loading' }
		2 { 'verifying' }
		3 { 'verified' }
		4 { 'failed' }
		else { 'unknown' }
	}
}

fn backend_label(b ProofBackend) string {
	return match b {
		.z3 { 'Z3' }
		.cvc5 { 'CVC5' }
		.lean { 'Lean' }
		.coq { 'Coq' }
		.agda { 'Agda' }
		.isabelle { 'Isabelle' }
		.idris2 { 'Idris2' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct InitResponse {
	slot    int
	backend string
	state   string
}

struct StateResponse {
	slot  int
	state string
}

struct VerifyResponse {
	slot   int
	state  string
	result string
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

pub fn init_session(backend_name string) !InitResponse {
	b := match backend_name {
		'z3' { int(ProofBackend.z3) }
		'cvc5' { int(ProofBackend.cvc5) }
		'lean' { int(ProofBackend.lean) }
		'coq' { int(ProofBackend.coq) }
		'agda' { int(ProofBackend.agda) }
		'isabelle' { int(ProofBackend.isabelle) }
		'idris2' { int(ProofBackend.idris2) }
		else { return error('unknown backend: ${backend_name}') }
	}
	slot := C.proof_init(b)
	if slot < 0 {
		return error('no session slots available')
	}
	return InitResponse{
		slot: slot
		backend: backend_name
		state: 'idle'
	}
}

pub fn load_obligation(slot int, backend_name string) !string {
	b := match backend_name {
		'z3' { int(ProofBackend.z3) }
		'cvc5' { int(ProofBackend.cvc5) }
		'lean' { int(ProofBackend.lean) }
		'coq' { int(ProofBackend.coq) }
		'agda' { int(ProofBackend.agda) }
		'isabelle' { int(ProofBackend.isabelle) }
		'idris2' { int(ProofBackend.idris2) }
		else { return error('unknown backend: ${backend_name}') }
	}
	result := C.proof_load(slot, b)
	return match result {
		0 { 'obligation loaded on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot load from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn verify(slot int) !string {
	result := C.proof_verify(slot)
	return match result {
		0 { 'verification started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot verify from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_result(slot int) VerifyResponse {
	s := C.proof_get_result(slot)
	state := state_label(s)
	result_str := match s {
		3 { 'proof complete' }
		4 { 'proof failed' }
		else { 'verification in progress' }
	}
	return VerifyResponse{
		slot: slot
		state: state
		result: result_str
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.proof_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn reset_session(slot int) !string {
	result := C.proof_reset(slot)
	return match result {
		0 { 'session ${slot} reset to idle' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot reset from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn release_session(slot int) !string {
	result := C.proof_release(slot)
	return match result {
		0 { 'session ${slot} released' }
		-1 { return error('slot ${slot} not active or already released') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.proof_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset_all() {
	C.proof_reset_all()
}
