// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — tRPC transport adapter.
//
// Implements a tRPC-compatible server for the ECHIDNA frontier LLM tactic
// advisory. tRPC provides type-safe RPC-over-HTTP with automatic
// serialisation, ideal for ReScript/TypeScript proof dashboards that
// consume the echidna-llm API with full type inference.
//
// Procedures:
//   Queries:
//     echidna.status      — get current session state
//     echidna.health      — adapter health check
//
//   Mutations:
//     echidna.suggestTactics  — suggest tactics for a proof goal
//     echidna.rankProvers     — rank provers for a goal
//     echidna.authenticate    — create ephemeral session
//     echidna.close           — close current session
//
// Wire format (HTTP):
//   Query:    GET  /echidna.status
//   Mutation: POST /echidna.suggestTactics  body: {"json": {input}}
//   Batch:    POST /  body: [{"path":"echidna.status","type":"query"}, ...]
//
// Response: {"result": {"data": {"json": ...}}}
// Error:    {"error": {"json": {"message": "...", "code": "..."}}}

module echidna_llm_trpc

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
// tRPC wire types
// ═══════════════════════════════════════════════════════════════════════

// tRPC error codes.
const trpc_bad_request = 'BAD_REQUEST'
const trpc_unauthorized = 'UNAUTHORIZED'
const trpc_not_found = 'NOT_FOUND'
const trpc_internal_error = 'INTERNAL_SERVER_ERROR'
const trpc_precondition_failed = 'PRECONDITION_FAILED'

// Inbound tRPC mutation request body.
struct TrpcMutationRequest {
	json json.RawMessage @[json: 'json']
}

// Outbound tRPC success response.
struct TrpcSuccessResponse {
	result TrpcResult
}

struct TrpcResult {
	data TrpcData
}

struct TrpcData {
	json json.RawMessage @[json: 'json']
}

// Outbound tRPC error response.
struct TrpcErrorResponse {
	error TrpcErrorEnvelope
}

struct TrpcErrorEnvelope {
	json TrpcErrorBody @[json: 'json']
}

struct TrpcErrorBody {
	message string
	code    string
}

// Batch request item.
struct TrpcBatchItem {
	path  string
	type_ string @[json: 'type']
	input json.RawMessage @[omitempty]
}

// ═══════════════════════════════════════════════════════════════════════
// Input types
// ═══════════════════════════════════════════════════════════════════════

struct SuggestTacticsInput {
	goal       string
	hypotheses string
	prover_id  int    @[json: 'proverId']
	top_k      int    @[json: 'topK'] = 10
	model      string = 'sonnet'
}

struct RankProversInput {
	goal  string
	model string = 'sonnet'
}

struct AuthenticateInput {
	token     string
	max_calls int @[json: 'maxCalls'] = 100
	expiry_ms int @[json: 'expiryMs'] = 60000
}

// ═══════════════════════════════════════════════════════════════════════
// Result types (inner "json" field of tRPC response)
// ═══════════════════════════════════════════════════════════════════════

struct SuggestTacticsOutput {
	success bool
	data    string
}

struct RankProversOutput {
	success bool
	data    string
}

struct AuthenticateOutput {
	success   bool
	state     string
	max_calls int @[json: 'maxCalls']
	expiry_ms int @[json: 'expiryMs']
}

struct StatusOutput {
	state         string
	session_valid bool @[json: 'sessionValid']
}

struct CloseOutput {
	success bool
	state   string
}

struct HealthOutput {
	status  string
	adapter string
}

// ═══════════════════════════════════════════════════════════════════════
// tRPC response helpers
// ═══════════════════════════════════════════════════════════════════════

// Format a successful tRPC response.
fn trpc_success(data string) string {
	return json.encode(TrpcSuccessResponse{
		result: TrpcResult{
			data: TrpcData{
				json: json.RawMessage(data.bytes())
			}
		}
	})
}

// Format a tRPC error response.
fn trpc_error(message string, code string) string {
	return json.encode(TrpcErrorResponse{
		error: TrpcErrorEnvelope{
			json: TrpcErrorBody{
				message: message
				code: code
			}
		}
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Procedure dispatcher — routes tRPC paths to handlers
// ═══════════════════════════════════════════════════════════════════════

// Dispatch a single tRPC procedure call. Takes the procedure path and
// the raw input JSON (from query string for queries, from POST body
// for mutations). Returns the tRPC-formatted response.
pub fn dispatch(path string, input string) string {
	return match path {
		'echidna.suggestTactics' { handle_suggest_tactics(input) }
		'echidna.rankProvers' { handle_rank_provers(input) }
		'echidna.authenticate' { handle_authenticate(input) }
		'echidna.status' { handle_status() }
		'echidna.close' { handle_close() }
		'echidna.health' { handle_health() }
		else { trpc_error('procedure not found: ${path}', trpc_not_found) }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Procedure handlers
// ═══════════════════════════════════════════════════════════════════════

fn handle_suggest_tactics(input string) string {
	// Parse the tRPC mutation body: {"json": {input}}
	body := json.decode(TrpcMutationRequest, input) or {
		return trpc_error('invalid request body: ${err}', trpc_bad_request)
	}
	inp := json.decode(SuggestTacticsInput, body.json.str()) or {
		return trpc_error('invalid input: ${err}', trpc_bad_request)
	}

	if C.echidna_llm_session_valid() != 1 {
		return trpc_error('session expired or call limit reached', trpc_unauthorized)
	}

	model := model_from_string(inp.model)
	hypotheses := if inp.hypotheses.len > 0 { inp.hypotheses } else { '[]' }

	result_ptr := C.echidna_llm_suggest_tactics(
		inp.goal.str, inp.goal.len,
		hypotheses.str, hypotheses.len,
		inp.prover_id, inp.top_k, model,
	)

	if result_ptr == unsafe { nil } {
		return trpc_error('tactic suggestion failed', trpc_internal_error)
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return trpc_success(json.encode(SuggestTacticsOutput{
		success: true
		data: result_str
	}))
}

fn handle_rank_provers(input string) string {
	body := json.decode(TrpcMutationRequest, input) or {
		return trpc_error('invalid request body: ${err}', trpc_bad_request)
	}
	inp := json.decode(RankProversInput, body.json.str()) or {
		return trpc_error('invalid input: ${err}', trpc_bad_request)
	}

	if C.echidna_llm_session_valid() != 1 {
		return trpc_error('session expired or call limit reached', trpc_unauthorized)
	}

	model := model_from_string(inp.model)
	result_ptr := C.echidna_llm_rank_provers(inp.goal.str, inp.goal.len, model)

	if result_ptr == unsafe { nil } {
		return trpc_error('prover ranking failed', trpc_internal_error)
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return trpc_success(json.encode(RankProversOutput{
		success: true
		data: result_str
	}))
}

fn handle_authenticate(input string) string {
	body := json.decode(TrpcMutationRequest, input) or {
		return trpc_error('invalid request body: ${err}', trpc_bad_request)
	}
	inp := json.decode(AuthenticateInput, body.json.str()) or {
		return trpc_error('invalid input: ${err}', trpc_bad_request)
	}

	result := C.echidna_llm_authenticate(inp.token.str, inp.token.len, inp.max_calls, inp.expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		code := if result == -1 { trpc_precondition_failed } else { trpc_bad_request }
		return trpc_error(msg, code)
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	return trpc_success(json.encode(AuthenticateOutput{
		success: true
		state: state_label(state)
		max_calls: inp.max_calls
		expiry_ms: inp.expiry_ms
	}))
}

fn handle_status() string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	return trpc_success(json.encode(StatusOutput{
		state: state_label(state)
		session_valid: valid
	}))
}

fn handle_close() string {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		return trpc_error('cannot close — no active session', trpc_precondition_failed)
	}

	return trpc_success(json.encode(CloseOutput{
		success: true
		state: state_label(state)
	}))
}

fn handle_health() string {
	return trpc_success(json.encode(HealthOutput{
		status: 'ok'
		adapter: 'echidna_llm_trpc'
	}))
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_trpc_health() {
	response := dispatch('echidna.health', '{}')
	assert response.contains('echidna_llm_trpc')
	assert response.contains('"result"')
}

fn test_trpc_status() {
	response := dispatch('echidna.status', '{}')
	assert response.contains('"result"')
	assert response.contains('unauthenticated') || response.contains('authenticated')
		|| response.contains('operating') || response.contains('closed')
}

fn test_trpc_suggest_no_session() {
	input := '{"json":{"goal":"forall n, n + 0 = n","proverId":0}}'
	response := dispatch('echidna.suggestTactics', input)
	assert response.contains('"error"')
	assert response.contains('session')
}

fn test_trpc_not_found() {
	response := dispatch('echidna.explode', '{}')
	assert response.contains('"error"')
	assert response.contains('procedure not found')
}

fn test_trpc_malformed_input() {
	response := dispatch('echidna.suggestTactics', '{"broken')
	assert response.contains('"error"')
	assert response.contains('invalid request')
}

fn test_trpc_error_format() {
	response := dispatch('echidna.notReal', '{}')
	// Should follow tRPC error envelope format
	assert response.contains('"code"')
	assert response.contains('"message"')
}
