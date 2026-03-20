// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — JSON-RPC 2.0 transport adapter.
//
// Implements a JSON-RPC 2.0 server exposing the ECHIDNA frontier LLM tactic
// advisory. Each method is registered on a Router which dispatches incoming
// requests to the appropriate HandlerFn. The server validates request
// structure, extracts typed parameters, invokes the Zig FFI, and returns
// structured JSON-RPC responses.
//
// Methods:
//   echidna.suggest_tactics — params: {goal, hypotheses, prover_id, top_k, model}
//   echidna.rank_provers   — params: {goal, model}
//   echidna.authenticate   — params: {token, max_calls, expiry_ms}
//   echidna.status         — no params
//   echidna.close          — no params
//   echidna.health         — no params
//
// Error codes follow JSON-RPC 2.0 conventions:
//   -32600  Invalid Request
//   -32601  Method not found
//   -32602  Invalid params
//   -32603  Internal error
//   -32000  Session invalid (application-defined)

module echidna_llm_jsonrpc

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
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'closed' }
		else { 'unknown' }
	}
}

// Map ModelTier string to its integer encoding for the FFI.
fn model_from_string(s string) int {
	return match s {
		'haiku' { 0 }
		'opus' { 2 }
		else { 1 } // default to sonnet
	}
}

// ═══════════════════════════════════════════════════════════════════════
// JSON-RPC 2.0 wire types
// ═══════════════════════════════════════════════════════════════════════

// Standard JSON-RPC 2.0 error codes.
const error_invalid_request = -32600
const error_method_not_found = -32601
const error_invalid_params = -32602
const error_internal = -32603
const error_session_invalid = -32000

// Inbound JSON-RPC 2.0 request envelope.
struct JsonRpcRequest {
	jsonrpc string          // must be "2.0"
	method  string          // dotted method name
	params  json.RawMessage // method-specific parameters
	id      json.RawMessage // request identifier (string or int)
}

// Outbound JSON-RPC 2.0 success response.
struct JsonRpcResponse {
	jsonrpc string          // always "2.0"
	result  json.RawMessage // method-specific result object
	id      json.RawMessage // echoed from request
}

// Outbound JSON-RPC 2.0 error response.
struct JsonRpcErrorResponse {
	jsonrpc string       // always "2.0"
	error   JsonRpcError
	id      json.RawMessage // echoed from request (or null)
}

// The error object inside a JSON-RPC error response.
struct JsonRpcError {
	code    int
	message string
}

// ═══════════════════════════════════════════════════════════════════════
// Parameter types — decoded from the "params" field of each request
// ═══════════════════════════════════════════════════════════════════════

// Parameters for echidna.suggest_tactics.
struct SuggestTacticsParams {
	goal       string
	hypotheses string // JSON array string, defaults to "[]"
	prover_id  int
	top_k      int = 10
	model      string = 'sonnet'
}

// Parameters for echidna.rank_provers.
struct RankProversParams {
	goal  string
	model string = 'sonnet'
}

// Parameters for echidna.authenticate.
struct AuthenticateParams {
	token     string
	max_calls int = 100
	expiry_ms int = 60000
}

// ═══════════════════════════════════════════════════════════════════════
// Result types — encoded into the "result" field of each response
// ═══════════════════════════════════════════════════════════════════════

// Result for echidna.suggest_tactics — wraps raw FFI JSON.
struct SuggestTacticsResult {
	success bool
	data    string
}

// Result for echidna.rank_provers — wraps raw FFI JSON.
struct RankProversResult {
	success bool
	data    string
}

// Result for echidna.authenticate.
struct AuthenticateResult {
	success   bool
	state     string
	max_calls int
	expiry_ms int
}

// Result for echidna.status.
struct StatusResult {
	state         string
	session_valid bool
}

// Result for echidna.close.
struct CloseResult {
	success bool
	state   string
}

// Result for echidna.health.
struct HealthResult {
	status  string
	adapter string
}

// ═══════════════════════════════════════════════════════════════════════
// Handler function type and Router
// ═══════════════════════════════════════════════════════════════════════

// A HandlerFn receives the raw params JSON and returns a result JSON
// string, or an error with a JSON-RPC error code.
type HandlerFn = fn (json.RawMessage) !(string)

// The Router maps method names to handler functions.
struct Router {
mut:
	handlers map[string]HandlerFn
}

// Create a new Router pre-loaded with all echidna-llm JSON-RPC methods.
pub fn Router.new() Router {
	mut r := Router{}
	r.handlers['echidna.suggest_tactics'] = handle_suggest_tactics
	r.handlers['echidna.rank_provers'] = handle_rank_provers
	r.handlers['echidna.authenticate'] = handle_authenticate
	r.handlers['echidna.status'] = handle_status
	r.handlers['echidna.close'] = handle_close
	r.handlers['echidna.health'] = handle_health
	return r
}

// Dispatch a raw JSON-RPC request string and return the response string.
// Handles request parsing, method lookup, and error wrapping.
pub fn (r &Router) dispatch(raw_request string) string {
	req := json.decode(JsonRpcRequest, raw_request) or {
		return json.encode(JsonRpcErrorResponse{
			jsonrpc: '2.0'
			error: JsonRpcError{
				code: error_invalid_request
				message: 'failed to parse JSON-RPC request: ${err}'
			}
			id: json.RawMessage('null'.bytes())
		})
	}

	if req.jsonrpc != '2.0' {
		return json.encode(JsonRpcErrorResponse{
			jsonrpc: '2.0'
			error: JsonRpcError{
				code: error_invalid_request
				message: 'jsonrpc field must be "2.0"'
			}
			id: req.id
		})
	}

	handler := r.handlers[req.method] or {
		return json.encode(JsonRpcErrorResponse{
			jsonrpc: '2.0'
			error: JsonRpcError{
				code: error_method_not_found
				message: 'method not found: ${req.method}'
			}
			id: req.id
		})
	}

	result_json := handler(req.params) or {
		return json.encode(JsonRpcErrorResponse{
			jsonrpc: '2.0'
			error: JsonRpcError{
				code: error_invalid_params
				message: err.msg()
			}
			id: req.id
		})
	}

	return json.encode(JsonRpcResponse{
		jsonrpc: '2.0'
		result: json.RawMessage(result_json.bytes())
		id: req.id
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Method handlers — each processes params and calls the Zig FFI
// ═══════════════════════════════════════════════════════════════════════

// Handle echidna.suggest_tactics: validate session, call FFI, return JSON.
fn handle_suggest_tactics(params json.RawMessage) !string {
	p := json.decode(SuggestTacticsParams, params.str()) or {
		return error('invalid params for echidna.suggest_tactics: ${err}')
	}

	if C.echidna_llm_session_valid() != 1 {
		return error('session expired or call limit reached')
	}

	model := model_from_string(p.model)
	hypotheses := if p.hypotheses.len > 0 { p.hypotheses } else { '[]' }

	result_ptr := C.echidna_llm_suggest_tactics(
		p.goal.str, p.goal.len,
		hypotheses.str, hypotheses.len,
		p.prover_id, p.top_k, model,
	)

	if result_ptr == unsafe { nil } {
		return error('tactic suggestion failed — session may have expired')
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(SuggestTacticsResult{
		success: true
		data: result_str
	})
}

// Handle echidna.rank_provers: validate session, call FFI, return JSON.
fn handle_rank_provers(params json.RawMessage) !string {
	p := json.decode(RankProversParams, params.str()) or {
		return error('invalid params for echidna.rank_provers: ${err}')
	}

	if C.echidna_llm_session_valid() != 1 {
		return error('session expired or call limit reached')
	}

	model := model_from_string(p.model)
	result_ptr := C.echidna_llm_rank_provers(p.goal.str, p.goal.len, model)

	if result_ptr == unsafe { nil } {
		return error('prover ranking failed')
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(RankProversResult{
		success: true
		data: result_str
	})
}

// Handle echidna.authenticate: create ephemeral session, transition to operating.
fn handle_authenticate(params json.RawMessage) !string {
	p := json.decode(AuthenticateParams, params.str()) or {
		return error('invalid params for echidna.authenticate: ${err}')
	}

	result := C.echidna_llm_authenticate(p.token.str, p.token.len, p.max_calls, p.expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		return error(msg)
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	return json.encode(AuthenticateResult{
		success: true
		state: state_label(state)
		max_calls: p.max_calls
		expiry_ms: p.expiry_ms
	})
}

// Handle echidna.status: return current session state.
fn handle_status(params json.RawMessage) !string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	return json.encode(StatusResult{
		state: state_label(state)
		session_valid: valid
	})
}

// Handle echidna.close: close the current session.
fn handle_close(params json.RawMessage) !string {
	result := C.echidna_llm_close()
	if result != 0 {
		return error('cannot close — no active session')
	}

	state := C.echidna_llm_get_state()
	return json.encode(CloseResult{
		success: true
		state: state_label(state)
	})
}

// Handle echidna.health: return adapter status.
fn handle_health(params json.RawMessage) !string {
	return json.encode(HealthResult{
		status: 'ok'
		adapter: 'echidna_llm_jsonrpc'
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that echidna.health returns a valid JSON-RPC 2.0 response.
fn test_jsonrpc_health() {
	router := Router.new()
	request := '{"jsonrpc":"2.0","method":"echidna.health","params":{},"id":1}'
	response := router.dispatch(request)

	assert response.contains('"result"')
	assert response.contains('echidna_llm_jsonrpc')
}

// Verify that echidna.status returns session state.
fn test_jsonrpc_status() {
	router := Router.new()
	request := '{"jsonrpc":"2.0","method":"echidna.status","params":{},"id":2}'
	response := router.dispatch(request)

	assert response.contains('"result"')
	// Should contain a known state label
	assert response.contains('unauthenticated') || response.contains('authenticated')
		|| response.contains('operating') || response.contains('closed')
}

// Verify that an unknown method returns error code -32601.
fn test_jsonrpc_method_not_found() {
	router := Router.new()
	request := '{"jsonrpc":"2.0","method":"echidna.explode","params":{},"id":3}'
	response := router.dispatch(request)

	assert response.contains('"error"')
	assert response.contains('method not found')
}

// Verify that suggest_tactics without a session returns a session error.
fn test_jsonrpc_suggest_no_session() {
	router := Router.new()
	request := '{"jsonrpc":"2.0","method":"echidna.suggest_tactics","params":{"goal":"forall n, n + 0 = n","prover_id":0},"id":4}'
	response := router.dispatch(request)

	assert response.contains('"error"')
	assert response.contains('session')
}

// Verify that a missing jsonrpc field returns an invalid request error.
fn test_jsonrpc_missing_version() {
	router := Router.new()
	request := '{"jsonrpc":"1.0","method":"echidna.health","params":{},"id":5}'
	response := router.dispatch(request)

	assert response.contains('"error"')
	assert response.contains('must be "2.0"')
}

// Verify that malformed JSON returns a parse error.
fn test_jsonrpc_malformed_json() {
	router := Router.new()
	request := '{"broken'
	response := router.dispatch(request)

	assert response.contains('"error"')
	assert response.contains('failed to parse')
}
