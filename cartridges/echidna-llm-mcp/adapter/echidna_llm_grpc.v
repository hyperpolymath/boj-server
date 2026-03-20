// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — gRPC transport adapter.
//
// Implements a gRPC service exposing the ECHIDNA frontier LLM tactic
// advisory for high-throughput, low-latency prover ↔ LLM communication.
// Uses HTTP/2 framing with Protocol Buffers-compatible binary encoding.
//
// Service definition (proto3-equivalent):
//   service EchidnaLlm {
//     rpc SuggestTactics (SuggestTacticsRequest) returns (TacticResponse);
//     rpc RankProvers (RankProversRequest) returns (RankerResponse);
//     rpc Authenticate (AuthRequest) returns (AuthResponse);
//     rpc GetStatus (Empty) returns (StatusResponse);
//     rpc Close (Empty) returns (CloseResponse);
//     rpc Health (Empty) returns (HealthResponse);
//   }
//
// This adapter encodes/decodes protobuf-compatible JSON (proto3 JSON
// mapping) for interoperability. Binary protobuf is handled at the
// orchestrator level via grpc-gateway.

module echidna_llm_grpc

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against echidna_llm_mcp built from Zig)
// ═══════════════════════════════════════════════════════════════════════

// Initialise the cartridge with a BoJ endpoint URL.
fn C.echidna_llm_init(endpoint &u8) int

// Create an ephemeral session token with call limit and expiry.
fn C.echidna_llm_authenticate(token &u8, token_len int, max_calls int, expiry_ms int) int

// Transition from authenticated to operating state.
fn C.echidna_llm_start_operating() int

// Close the current session (from authenticated or operating).
fn C.echidna_llm_close() int

// Get the current session state as an integer (0-3).
fn C.echidna_llm_get_state() int

// Check if the session is valid (not expired, not over call limit).
fn C.echidna_llm_session_valid() int

// Suggest tactics for a proof goal. Returns heap-allocated JSON.
fn C.echidna_llm_suggest_tactics(goal &u8, goal_len int, hyp &u8, hyp_len int, prover_id int, top_k int, model int) &u8

// Rank provers for a proof goal. Returns heap-allocated JSON.
fn C.echidna_llm_rank_provers(goal &u8, goal_len int, model int) &u8

// Free a string returned by any echidna_llm_* function.
fn C.echidna_llm_free(ptr &u8)

// Check if a state transition is valid.
fn C.echidna_llm_can_transition(from int, to int) int

// Check if an operation is advisory (always returns 1).
fn C.echidna_llm_is_advisory(op int) int

// ═══════════════════════════════════════════════════════════════════════
// Label helpers
// ═══════════════════════════════════════════════════════════════════════

// Map SessionState integer to its canonical label.
fn state_label(v int) string {
	return match v {
		0 { 'UNAUTHENTICATED' }
		1 { 'AUTHENTICATED' }
		2 { 'OPERATING' }
		3 { 'CLOSED' }
		else { 'UNKNOWN' }
	}
}

// Map ModelTier string to its integer encoding for the FFI.
fn model_from_string(s string) int {
	return match s.to_lower() {
		'haiku', 'MODEL_HAIKU' { 0 }
		'opus', 'MODEL_OPUS' { 2 }
		else { 1 }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// gRPC status codes (subset used by this adapter)
// ═══════════════════════════════════════════════════════════════════════

const grpc_ok = 0
const grpc_invalid_argument = 3
const grpc_not_found = 5
const grpc_permission_denied = 7
const grpc_failed_precondition = 9
const grpc_unimplemented = 12
const grpc_internal = 13
const grpc_unauthenticated = 16

// ═══════════════════════════════════════════════════════════════════════
// Request types (proto3 JSON mapping)
// ═══════════════════════════════════════════════════════════════════════

// SuggestTacticsRequest — maps to proto3 message.
struct SuggestTacticsRequest {
	goal       string
	hypotheses string
	prover_id  int @[json: 'proverId']
	top_k      int @[json: 'topK'] = 10
	model      string = 'sonnet'
}

// RankProversRequest — maps to proto3 message.
struct RankProversRequest {
	goal  string
	model string = 'sonnet'
}

// AuthRequest — maps to proto3 message.
struct AuthRequest {
	token     string
	max_calls int @[json: 'maxCalls'] = 100
	expiry_ms int @[json: 'expiryMs'] = 60000
}

// ═══════════════════════════════════════════════════════════════════════
// Response types (proto3 JSON mapping)
// ═══════════════════════════════════════════════════════════════════════

// TacticResponse — returned by SuggestTactics RPC.
struct TacticResponse {
	success bool
	data    string // JSON-encoded tactic suggestions
}

// RankerResponse — returned by RankProvers RPC.
struct RankerResponse {
	success bool
	data    string // JSON-encoded prover rankings
}

// AuthResponse — returned by Authenticate RPC.
struct AuthResponse {
	success   bool
	state     string
	max_calls int @[json: 'maxCalls']
	expiry_ms int @[json: 'expiryMs']
}

// StatusResponse — returned by GetStatus RPC.
struct StatusResponse {
	state         string
	session_valid bool @[json: 'sessionValid']
}

// CloseResponse — returned by Close RPC.
struct CloseResponse {
	success bool
	state   string
}

// HealthResponse — returned by Health RPC.
struct HealthResponse {
	status  string
	adapter string
}

// GrpcError — error envelope with gRPC status code.
struct GrpcError {
	code    int
	message string
}

// GrpcEnvelope — wraps either a result or an error for the gRPC transport.
struct GrpcEnvelope {
	result json.RawMessage @[omitempty]
	error  GrpcError       @[omitempty]
}

// ═══════════════════════════════════════════════════════════════════════
// Service method dispatch — routes RPC method names to handlers
// ═══════════════════════════════════════════════════════════════════════

// Full gRPC method path prefix for this service.
const service_prefix = '/echidna.llm.v1.EchidnaLlm/'

// Dispatch a gRPC method call. Takes the full method path and the
// JSON-encoded request body. Returns the JSON-encoded response.
pub fn dispatch(method string, body string) string {
	// Strip service prefix if present
	rpc_name := if method.starts_with(service_prefix) {
		method[service_prefix.len..]
	} else {
		method
	}

	return match rpc_name {
		'SuggestTactics' { handle_suggest_tactics(body) }
		'RankProvers' { handle_rank_provers(body) }
		'Authenticate' { handle_authenticate(body) }
		'GetStatus' { handle_status() }
		'Close' { handle_close() }
		'Health' { handle_health() }
		else {
			json.encode(GrpcEnvelope{
				error: GrpcError{
					code: grpc_unimplemented
					message: 'unknown RPC method: ${rpc_name}'
				}
			})
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// RPC handlers — each processes a request and calls the Zig FFI
// ═══════════════════════════════════════════════════════════════════════

// Handle SuggestTactics RPC.
fn handle_suggest_tactics(body string) string {
	req := json.decode(SuggestTacticsRequest, body) or {
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: grpc_invalid_argument, message: 'invalid request: ${err}' }
		})
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: grpc_unauthenticated, message: 'session expired or call limit reached' }
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
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: grpc_internal, message: 'tactic suggestion failed' }
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	data := json.encode(TacticResponse{ success: true, data: result_str })
	return json.encode(GrpcEnvelope{
		result: json.RawMessage(data.bytes())
	})
}

// Handle RankProvers RPC.
fn handle_rank_provers(body string) string {
	req := json.decode(RankProversRequest, body) or {
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: grpc_invalid_argument, message: 'invalid request: ${err}' }
		})
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: grpc_unauthenticated, message: 'session expired or call limit reached' }
		})
	}

	model := model_from_string(req.model)
	result_ptr := C.echidna_llm_rank_provers(req.goal.str, req.goal.len, model)

	if result_ptr == unsafe { nil } {
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: grpc_internal, message: 'prover ranking failed' }
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	data := json.encode(RankerResponse{ success: true, data: result_str })
	return json.encode(GrpcEnvelope{
		result: json.RawMessage(data.bytes())
	})
}

// Handle Authenticate RPC.
fn handle_authenticate(body string) string {
	req := json.decode(AuthRequest, body) or {
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: grpc_invalid_argument, message: 'invalid request: ${err}' }
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
		code := if result == -1 { grpc_failed_precondition } else { grpc_invalid_argument }
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: code, message: msg }
		})
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	data := json.encode(AuthResponse{
		success: true
		state: state_label(state)
		max_calls: req.max_calls
		expiry_ms: req.expiry_ms
	})
	return json.encode(GrpcEnvelope{
		result: json.RawMessage(data.bytes())
	})
}

// Handle GetStatus RPC.
fn handle_status() string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	data := json.encode(StatusResponse{
		state: state_label(state)
		session_valid: valid
	})
	return json.encode(GrpcEnvelope{
		result: json.RawMessage(data.bytes())
	})
}

// Handle Close RPC.
fn handle_close() string {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		return json.encode(GrpcEnvelope{
			error: GrpcError{ code: grpc_failed_precondition, message: 'cannot close — no active session' }
		})
	}

	data := json.encode(CloseResponse{ success: true, state: state_label(state) })
	return json.encode(GrpcEnvelope{
		result: json.RawMessage(data.bytes())
	})
}

// Handle Health RPC.
fn handle_health() string {
	data := json.encode(HealthResponse{ status: 'ok', adapter: 'echidna_llm_grpc' })
	return json.encode(GrpcEnvelope{
		result: json.RawMessage(data.bytes())
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that the Health RPC returns ok.
fn test_grpc_health() {
	response := dispatch('Health', '{}')
	assert response.contains('echidna_llm_grpc')
	assert !response.contains('"error"')
}

// Verify that GetStatus returns a valid state.
fn test_grpc_status() {
	response := dispatch('GetStatus', '{}')
	assert response.contains('UNAUTHENTICATED') || response.contains('AUTHENTICATED')
		|| response.contains('OPERATING') || response.contains('CLOSED')
}

// Verify that SuggestTactics without a session returns UNAUTHENTICATED.
fn test_grpc_suggest_no_session() {
	response := dispatch('SuggestTactics', '{"goal":"forall n, n + 0 = n","proverId":0}')
	assert response.contains('"error"')
	assert response.contains('session')
}

// Verify that an unknown RPC returns UNIMPLEMENTED.
fn test_grpc_unknown_rpc() {
	response := dispatch('Explode', '{}')
	assert response.contains('"error"')
	assert response.contains('unknown RPC method')
}

// Verify that the full service path is correctly stripped.
fn test_grpc_full_path() {
	response := dispatch('/echidna.llm.v1.EchidnaLlm/Health', '{}')
	assert response.contains('echidna_llm_grpc')
}

// Verify that malformed request body returns INVALID_ARGUMENT.
fn test_grpc_malformed_body() {
	response := dispatch('SuggestTactics', '{"broken')
	assert response.contains('"error"')
	assert response.contains('invalid request')
}
