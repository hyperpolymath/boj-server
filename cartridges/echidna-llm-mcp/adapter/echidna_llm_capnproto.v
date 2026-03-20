// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — Cap'n Proto transport adapter.
//
// Implements a Cap'n Proto RPC interface for the ECHIDNA frontier LLM
// tactic advisory. Cap'n Proto provides zero-copy, zero-parse binary
// serialisation — the fastest possible wire format for prover ↔ LLM
// communication in latency-critical proof dispatch.
//
// Interface (Cap'n Proto schema equivalent):
//   interface EchidnaLlm {
//     suggestTactics @0 (request :SuggestTacticsRequest) -> (response :TacticResponse);
//     rankProvers    @1 (request :RankProversRequest) -> (response :RankerResponse);
//     authenticate   @2 (request :AuthRequest) -> (response :AuthResponse);
//     getStatus      @3 () -> (response :StatusResponse);
//     closeSession   @4 () -> (response :CloseResponse);
//     health         @5 () -> (response :HealthResponse);
//   }
//
// This adapter uses JSON-over-binary framing for the V-lang layer.
// The actual Cap'n Proto binary encoding is handled by the Zig FFI
// layer (zero-copy struct packing) and the orchestrator's capnp
// transport. This module provides the dispatch logic and FFI bridge.
//
// Message framing:
//   Header: [method_id: u16] [payload_len: u32]
//   Body:   [payload: bytes]  (JSON for this layer, capnp binary at wire)

module echidna_llm_capnproto

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
// Label helpers
// ═══════════════════════════════════════════════════════════════════════

fn state_label(v int) string {
	return match v {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'closed' }
		else { 'unknown' }
	}
}

fn model_from_string(s string) int {
	return match s {
		'haiku' { 0 }
		'opus' { 2 }
		else { 1 }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Cap'n Proto method IDs (matching @N annotations in the schema)
// ═══════════════════════════════════════════════════════════════════════

const method_suggest_tactics = u16(0)
const method_rank_provers = u16(1)
const method_authenticate = u16(2)
const method_get_status = u16(3)
const method_close_session = u16(4)
const method_health = u16(5)

// ═══════════════════════════════════════════════════════════════════════
// Message types — JSON representations of Cap'n Proto structs
// ═══════════════════════════════════════════════════════════════════════

// Cap'n Proto message header.
pub struct CapnpHeader {
pub:
	method_id   u16
	payload_len u32
}

// Request types.
struct SuggestTacticsRequest {
	goal       string
	hypotheses string
	prover_id  int    @[json: 'proverId']
	top_k      int    @[json: 'topK'] = 10
	model      string = 'sonnet'
}

struct RankProversRequest {
	goal  string
	model string = 'sonnet'
}

struct AuthRequest {
	token     string
	max_calls int @[json: 'maxCalls'] = 100
	expiry_ms int @[json: 'expiryMs'] = 60000
}

// Response types.
struct TacticResponse {
	success bool
	data    string
}

struct RankerResponse {
	success bool
	data    string
}

struct AuthResponse {
	success   bool
	state     string
	max_calls int @[json: 'maxCalls']
	expiry_ms int @[json: 'expiryMs']
}

struct StatusResponse {
	state         string
	session_valid bool @[json: 'sessionValid']
}

struct CloseResponse {
	success bool
	state   string
}

struct HealthResponse {
	status  string
	adapter string
}

// Error response for failed method calls.
struct ErrorResponse {
	error     string
	method_id u16 @[json: 'methodId']
}

// ═══════════════════════════════════════════════════════════════════════
// Dispatch — routes method IDs to handlers
// ═══════════════════════════════════════════════════════════════════════

// Dispatch a Cap'n Proto method call by ID. Takes the method ID and
// JSON-encoded payload (the V-lang layer works with JSON; binary
// capnp encoding happens at the Zig FFI/orchestrator level).
// Returns the JSON-encoded response.
pub fn dispatch(method_id u16, payload string) string {
	return match method_id {
		method_suggest_tactics { handle_suggest_tactics(payload) }
		method_rank_provers { handle_rank_provers(payload) }
		method_authenticate { handle_authenticate(payload) }
		method_get_status { handle_status() }
		method_close_session { handle_close() }
		method_health { handle_health() }
		else {
			json.encode(ErrorResponse{
				error: 'unknown method ID: ${method_id}'
				method_id: method_id
			})
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Method handlers
// ═══════════════════════════════════════════════════════════════════════

fn handle_suggest_tactics(payload string) string {
	req := json.decode(SuggestTacticsRequest, payload) or {
		return json.encode(ErrorResponse{
			error: 'invalid request: ${err}'
			method_id: method_suggest_tactics
		})
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(ErrorResponse{
			error: 'session expired or call limit reached'
			method_id: method_suggest_tactics
		})
	}

	model := model_from_string(req.model)
	hypotheses := if req.hypotheses.len > 0 { req.hypotheses } else { '[]' }

	result_ptr := C.echidna_llm_suggest_tactics(
		req.goal.str, req.goal.len,
		hypotheses.str, hypotheses.len,
		req.prover_id, req.top_k, model,
	)

	if result_ptr == unsafe { nil } {
		return json.encode(ErrorResponse{
			error: 'tactic suggestion failed'
			method_id: method_suggest_tactics
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(TacticResponse{ success: true, data: result_str })
}

fn handle_rank_provers(payload string) string {
	req := json.decode(RankProversRequest, payload) or {
		return json.encode(ErrorResponse{
			error: 'invalid request: ${err}'
			method_id: method_rank_provers
		})
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(ErrorResponse{
			error: 'session expired or call limit reached'
			method_id: method_rank_provers
		})
	}

	model := model_from_string(req.model)
	result_ptr := C.echidna_llm_rank_provers(req.goal.str, req.goal.len, model)

	if result_ptr == unsafe { nil } {
		return json.encode(ErrorResponse{
			error: 'prover ranking failed'
			method_id: method_rank_provers
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(RankerResponse{ success: true, data: result_str })
}

fn handle_authenticate(payload string) string {
	req := json.decode(AuthRequest, payload) or {
		return json.encode(ErrorResponse{
			error: 'invalid request: ${err}'
			method_id: method_authenticate
		})
	}

	result := C.echidna_llm_authenticate(req.token.str, req.token.len, req.max_calls, req.expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		return json.encode(ErrorResponse{
			error: msg
			method_id: method_authenticate
		})
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	return json.encode(AuthResponse{
		success: true
		state: state_label(state)
		max_calls: req.max_calls
		expiry_ms: req.expiry_ms
	})
}

fn handle_status() string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	return json.encode(StatusResponse{
		state: state_label(state)
		session_valid: valid
	})
}

fn handle_close() string {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		return json.encode(ErrorResponse{
			error: 'cannot close — no active session'
			method_id: method_close_session
		})
	}

	return json.encode(CloseResponse{ success: true, state: state_label(state) })
}

fn handle_health() string {
	return json.encode(HealthResponse{ status: 'ok', adapter: 'echidna_llm_capnproto' })
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_capnp_health() {
	response := dispatch(method_health, '{}')
	decoded := json.decode(HealthResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.status == 'ok'
	assert decoded.adapter == 'echidna_llm_capnproto'
}

fn test_capnp_status() {
	response := dispatch(method_get_status, '{}')
	decoded := json.decode(StatusResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
}

fn test_capnp_suggest_no_session() {
	response := dispatch(method_suggest_tactics, '{"goal":"forall n, n + 0 = n","proverId":0}')
	assert response.contains('session')
}

fn test_capnp_rank_no_session() {
	response := dispatch(method_rank_provers, '{"goal":"P -> Q -> P"}')
	assert response.contains('session')
}

fn test_capnp_unknown_method() {
	response := dispatch(99, '{}')
	decoded := json.decode(ErrorResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.error.contains('unknown method ID')
	assert decoded.method_id == 99
}

fn test_capnp_malformed_payload() {
	response := dispatch(method_suggest_tactics, '{"broken')
	assert response.contains('invalid request')
}

fn test_capnp_method_id_values() {
	// Verify method IDs match schema @N annotations
	assert method_suggest_tactics == 0
	assert method_rank_provers == 1
	assert method_authenticate == 2
	assert method_get_status == 3
	assert method_close_session == 4
	assert method_health == 5
}
