// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (echidna_llm_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides frontier LLM tactic advisory for ECHIDNA's proof dispatch pipeline.
//
// All operations are advisory-only (proven in Idris2, enforced in Zig).
// Ephemeral session tokens provide transaction-based security.

module echidna_llm_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against echidna_llm_mcp built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.echidna_llm_init(endpoint &u8) int
fn C.echidna_llm_authenticate(token &u8, token_len int, max_calls int, expiry_ms int) int
fn C.echidna_llm_start_operating() int
fn C.echidna_llm_close() int
fn C.echidna_llm_get_state() int
fn C.echidna_llm_session_valid() int
fn C.echidna_llm_suggest_tactics(goal &u8, goal_len int, hyp &u8, hyp_len int, prover_id int, top_k int, model int) &u8
fn C.echidna_llm_rank_provers(goal &u8, goal_len int, model int) &u8
fn C.echidna_llm_free(ptr &u8)
fn C.echidna_llm_can_transition(from int, to int) int
fn C.echidna_llm_is_advisory(op int) int

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum SessionState {
	unauthenticated = 0
	authenticated = 1
	operating = 2
	closed = 3
}

enum ModelTier {
	haiku = 0
	sonnet = 1
	opus = 2
}

enum LlmOperation {
	suggest_tactics = 0
	rank_provers = 1
	decompose_goal = 2
	generate_lemmas = 3
	classify_goal = 4
}

struct ApiResponse {
	success bool
	data    string
	error   string
}

fn model_from_string(s string) ModelTier {
	return match s {
		'haiku' { .haiku }
		'opus' { .opus }
		else { .sonnet }
	}
}

fn state_to_string(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'closed' }
		else { 'unknown' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main BoJ adapter router)
// ═══════════════════════════════════════════════════════════════════════

// Initialise the cartridge
pub fn init(endpoint string) !ApiResponse {
	result := C.echidna_llm_init(endpoint.str)
	if result != 0 {
		return ApiResponse{
			success: false
			error: 'Failed to initialise echidna-llm cartridge'
		}
	}
	return ApiResponse{
		success: true
		data: '{"status":"initialised","endpoint":"${endpoint}"}'
	}
}

// Create an ephemeral session for a proof attempt
pub fn authenticate(token string, max_calls int, expiry_ms int) !ApiResponse {
	result := C.echidna_llm_authenticate(token.str, token.len, max_calls, expiry_ms)
	return match result {
		0 {
			// Transition to operating immediately
			C.echidna_llm_start_operating()
			ApiResponse{
				success: true
				data: '{"status":"authenticated","max_calls":${max_calls},"expiry_ms":${expiry_ms}}'
			}
		}
		-1 {
			ApiResponse{
				success: false
				error: 'Invalid state transition — session already active'
			}
		}
		-2 {
			ApiResponse{
				success: false
				error: 'max_calls must be between 1 and 1000'
			}
		}
		else {
			ApiResponse{
				success: false
				error: 'Authentication failed with code ${result}'
			}
		}
	}
}

// Suggest tactics for a proof goal
pub fn suggest_tactics(goal string, hypotheses string, prover_id int, top_k int, model string) !ApiResponse {
	// Check session validity
	if C.echidna_llm_session_valid() != 1 {
		return ApiResponse{
			success: false
			error: 'Session expired or call limit reached'
		}
	}

	model_tier := model_from_string(model)
	result_ptr := C.echidna_llm_suggest_tactics(
		goal.str, goal.len,
		hypotheses.str, hypotheses.len,
		prover_id, top_k,
		int(model_tier),
	)

	if result_ptr == unsafe { nil } {
		return ApiResponse{
			success: false
			error: 'Tactic suggestion failed — session may have expired'
		}
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return ApiResponse{
		success: true
		data: result_str
	}
}

// Rank provers for a goal
pub fn rank_provers(goal string, model string) !ApiResponse {
	if C.echidna_llm_session_valid() != 1 {
		return ApiResponse{
			success: false
			error: 'Session expired or call limit reached'
		}
	}

	model_tier := model_from_string(model)
	result_ptr := C.echidna_llm_rank_provers(goal.str, goal.len, int(model_tier))

	if result_ptr == unsafe { nil } {
		return ApiResponse{
			success: false
			error: 'Prover ranking failed'
		}
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return ApiResponse{
		success: true
		data: result_str
	}
}

// Get current session state
pub fn get_status() !ApiResponse {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid()
	return ApiResponse{
		success: true
		data: '{"state":"${state_to_string(state)}","session_valid":${valid == 1}}'
	}
}

// Close the current session
pub fn close_session() !ApiResponse {
	result := C.echidna_llm_close()
	if result != 0 {
		return ApiResponse{
			success: false
			error: 'Cannot close — no active session'
		}
	}
	return ApiResponse{
		success: true
		data: '{"status":"closed"}'
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Main dispatch (called by BoJ cartridge router)
// ═══════════════════════════════════════════════════════════════════════

pub fn invoke(operation string, params json.Any) !ApiResponse {
	return match operation {
		'init' {
			endpoint := params.str('endpoint') or { 'http://localhost:7700' }
			init(endpoint)!
		}
		'authenticate' {
			token := params.str('token') or { return error('missing token') }
			max_calls := params.int('max_calls') or { 100 }
			expiry_ms := params.int('expiry_ms') or { 60000 }
			authenticate(token, max_calls, expiry_ms)!
		}
		'suggest_tactics' {
			goal := params.str('goal') or { return error('missing goal') }
			hypotheses := params.str('hypotheses') or { '[]' }
			prover_id := params.int('prover_id') or { 0 }
			top_k := params.int('top_k') or { 10 }
			model := params.str('model') or { 'sonnet' }
			suggest_tactics(goal, hypotheses, prover_id, top_k, model)!
		}
		'rank_provers' {
			goal := params.str('goal') or { return error('missing goal') }
			model := params.str('model') or { 'sonnet' }
			rank_provers(goal, model)!
		}
		'status' {
			get_status()!
		}
		'close' {
			close_session()!
		}
		else {
			ApiResponse{
				success: false
				error: 'Unknown operation: ${operation}'
			}
		}
	}
}
