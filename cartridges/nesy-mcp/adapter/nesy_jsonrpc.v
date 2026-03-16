// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — JSON-RPC 2.0 transport adapter.
//
// Implements a JSON-RPC 2.0 server exposing the NeSy harmonization engine.
// Each method is registered on a Router which dispatches incoming requests
// to the appropriate HandlerFn. The server validates request structure,
// extracts typed parameters, invokes the Zig FFI, and returns structured
// JSON-RPC responses.
//
// Methods:
//   nesy.harmonize  — params: {neural: string, symbolic: string}
//   nesy.drift      — params: {kind: string}
//   nesy.mode       — params: {mode: string}
//   nesy.health     — no params
//
// Error codes follow JSON-RPC 2.0 conventions:
//   -32600  Invalid Request
//   -32601  Method not found
//   -32602  Invalid params
//   -32603  Internal error

module nesy_jsonrpc

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against nesy_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

// Harmonize a neural verdict with a symbolic verdict, returning
// a HarmonizedVerdict integer. Symbolic truth always overrides.
fn C.nesy_harmonize(neural int, symbolic int) int

// Compute a confidence level for the harmonization result.
fn C.nesy_confidence(neural int, symbolic int) int

// Given a DriftKind integer, return the recommended DriftAction.
fn C.nesy_recommend_drift_action(drift int) int

// Returns 1 if the given ReasoningMode uses symbolic reasoning.
fn C.nesy_mode_uses_symbolic(mode int) int

// Returns 1 if the given ReasoningMode uses neural reasoning.
fn C.nesy_mode_uses_neural(mode int) int

// Returns 1 if the given grounding level is considered trusted.
fn C.nesy_grounding_is_trusted(g int) int

// Returns 1 if the given DriftKind is urgent (severity >= 4).
fn C.nesy_drift_is_urgent(drift int) int

// ═══════════════════════════════════════════════════════════════════════
// Label helpers — convert integer encodings to human-readable strings
// ═══════════════════════════════════════════════════════════════════════

fn neural_label(v int) string {
	return match v {
		1 { 'probable_safe' }
		2 { 'unsure' }
		3 { 'probable_unsafe' }
		else { 'unknown' }
	}
}

fn symbolic_label(v int) string {
	return match v {
		1 { 'proven_safe' }
		2 { 'no_proof' }
		3 { 'proven_unsafe' }
		else { 'unknown' }
	}
}

fn harmonized_label(v int) string {
	return match v {
		1 { 'certified_safe' }
		2 { 'requires_review' }
		3 { 'critical_unsafe' }
		else { 'unknown' }
	}
}

fn confidence_label(v int) string {
	return match v {
		1 { 'low' }
		2 { 'high' }
		3 { 'absolute' }
		else { 'unknown' }
	}
}

fn drift_kind_label(v int) string {
	return match v {
		0 { 'NoDrift' }
		1 { 'SemanticDrift' }
		2 { 'ConfidenceDrift' }
		3 { 'FactualDrift' }
		4 { 'TemporalDrift' }
		5 { 'CatastrophicDrift' }
		else { 'Unknown' }
	}
}

fn drift_action_label(v int) string {
	return match v {
		0 { 'LogAndAccept' }
		1 { 'FlagForReview' }
		2 { 'RejectNeural' }
		3 { 'RetryNeural' }
		4 { 'Escalate' }
		5 { 'Halt' }
		else { 'Unknown' }
	}
}

fn reasoning_mode_label(v int) string {
	return match v {
		0 { 'Symbolic' }
		1 { 'Neural' }
		2 { 'SymToNeural' }
		3 { 'NeuralToSym' }
		4 { 'Ensemble' }
		5 { 'Cascade' }
		else { 'Unknown' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// String-to-int parsers
// ═══════════════════════════════════════════════════════════════════════

fn parse_neural(s string) !int {
	return match s {
		'probable_safe' { 1 }
		'unsure' { 2 }
		'probable_unsafe' { 3 }
		else { error('unknown neural verdict: ${s}') }
	}
}

fn parse_symbolic(s string) !int {
	return match s {
		'proven_safe' { 1 }
		'no_proof' { 2 }
		'proven_unsafe' { 3 }
		else { error('unknown symbolic verdict: ${s}') }
	}
}

fn parse_drift(s string) !int {
	return match s.to_lower() {
		'nodrift', 'no_drift', 'none' { 0 }
		'semanticdrift', 'semantic' { 1 }
		'confidencedrift', 'confidence' { 2 }
		'factualdrift', 'factual' { 3 }
		'temporaldrift', 'temporal' { 4 }
		'catastrophicdrift', 'catastrophic' { 5 }
		else { error('unknown drift kind: ${s}') }
	}
}

fn parse_mode(s string) !int {
	return match s.to_lower() {
		'symbolic' { 0 }
		'neural' { 1 }
		'symtoneural' { 2 }
		'neuraltosym' { 3 }
		'ensemble' { 4 }
		'cascade' { 5 }
		else { error('unknown reasoning mode: ${s}') }
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

// Inbound JSON-RPC 2.0 request envelope.
struct JsonRpcRequest {
	jsonrpc string            // must be "2.0"
	method  string            // dotted method name
	params  json.RawMessage   // method-specific parameters
	id      json.RawMessage   // request identifier (string or int)
}

// Outbound JSON-RPC 2.0 success response.
struct JsonRpcResponse {
	jsonrpc string          // always "2.0"
	result  json.RawMessage // method-specific result object
	id      json.RawMessage // echoed from request
}

// Outbound JSON-RPC 2.0 error response.
struct JsonRpcErrorResponse {
	jsonrpc string          // always "2.0"
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

// Parameters for nesy.harmonize: two verdict label strings.
struct HarmonizeParams {
	neural   string
	symbolic string
}

// Parameters for nesy.drift: a single drift kind label.
struct DriftParams {
	kind string
}

// Parameters for nesy.mode: a single reasoning mode label.
struct ModeParams {
	mode string
}

// ═══════════════════════════════════════════════════════════════════════
// Result types — encoded into the "result" field of each response
// ═══════════════════════════════════════════════════════════════════════

// Result for nesy.harmonize.
struct HarmonizeResult {
	neural_input   string
	symbolic_input string
	verdict        string
	confidence     string
	symbolic_wins  bool
}

// Result for nesy.drift.
struct DriftResult {
	drift              string
	severity           int
	urgent             bool
	recommended_action string
}

// Result for nesy.mode.
struct ModeResult {
	mode          string
	uses_symbolic bool
	uses_neural   bool
	is_hybrid     bool
}

// Result for nesy.health.
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

// Create a new Router pre-loaded with all NeSy JSON-RPC methods.
pub fn Router.new() Router {
	mut r := Router{}
	r.handlers['nesy.harmonize'] = handle_harmonize
	r.handlers['nesy.drift'] = handle_drift
	r.handlers['nesy.mode'] = handle_mode
	r.handlers['nesy.health'] = handle_health
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

// Handle nesy.harmonize: decode neural + symbolic verdicts, call FFI,
// return the harmonized verdict and confidence.
fn handle_harmonize(params json.RawMessage) !string {
	p := json.decode(HarmonizeParams, params.str()) or {
		return error('invalid params for nesy.harmonize: ${err}')
	}
	neural := parse_neural(p.neural)!
	symbolic := parse_symbolic(p.symbolic)!

	result := C.nesy_harmonize(neural, symbolic)
	conf := C.nesy_confidence(neural, symbolic)

	return json.encode(HarmonizeResult{
		neural_input: neural_label(neural)
		symbolic_input: symbolic_label(symbolic)
		verdict: harmonized_label(result)
		confidence: confidence_label(conf)
		symbolic_wins: symbolic != 2
	})
}

// Handle nesy.drift: decode drift kind, call FFI, return drift report.
fn handle_drift(params json.RawMessage) !string {
	p := json.decode(DriftParams, params.str()) or {
		return error('invalid params for nesy.drift: ${err}')
	}
	drift_int := parse_drift(p.kind)!
	action := C.nesy_recommend_drift_action(drift_int)

	return json.encode(DriftResult{
		drift: drift_kind_label(drift_int)
		severity: drift_int
		urgent: C.nesy_drift_is_urgent(drift_int) == 1
		recommended_action: drift_action_label(action)
	})
}

// Handle nesy.mode: decode reasoning mode, call FFI, return mode info.
fn handle_mode(params json.RawMessage) !string {
	p := json.decode(ModeParams, params.str()) or {
		return error('invalid params for nesy.mode: ${err}')
	}
	mode_int := parse_mode(p.mode)!
	sym := C.nesy_mode_uses_symbolic(mode_int) == 1
	neur := C.nesy_mode_uses_neural(mode_int) == 1

	return json.encode(ModeResult{
		mode: reasoning_mode_label(mode_int)
		uses_symbolic: sym
		uses_neural: neur
		is_hybrid: sym && neur
	})
}

// Handle nesy.health: no parameters needed, return adapter status.
fn handle_health(params json.RawMessage) !string {
	return json.encode(HealthResult{
		status: 'ok'
		adapter: 'nesy_jsonrpc'
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that a well-formed nesy.harmonize request returns the correct
// JSON-RPC 2.0 response with symbolic override.
fn test_jsonrpc_harmonize() {
	router := Router.new()
	request := '{"jsonrpc":"2.0","method":"nesy.harmonize","params":{"neural":"unsure","symbolic":"proven_safe"},"id":1}'
	response := router.dispatch(request)

	// Response must contain "result" (not "error")
	assert response.contains('"result"')
	assert response.contains('certified_safe') || response.contains('requires_review')
	assert response.contains('"jsonrpc":"2.0"') || response.contains('"jsonrpc": "2.0"')
}

// Verify that an unknown method returns error code -32601.
fn test_jsonrpc_method_not_found() {
	router := Router.new()
	request := '{"jsonrpc":"2.0","method":"nesy.explode","params":{},"id":2}'
	response := router.dispatch(request)

	assert response.contains('"error"')
	assert response.contains('method not found')
}

// Verify that invalid params return error code -32602.
fn test_jsonrpc_invalid_params() {
	router := Router.new()
	request := '{"jsonrpc":"2.0","method":"nesy.harmonize","params":{"neural":"banana","symbolic":"proven_safe"},"id":3}'
	response := router.dispatch(request)

	assert response.contains('"error"')
	assert response.contains('unknown neural verdict')
}

// Verify that nesy.health returns status ok with no params.
fn test_jsonrpc_health() {
	router := Router.new()
	request := '{"jsonrpc":"2.0","method":"nesy.health","params":{},"id":4}'
	response := router.dispatch(request)

	assert response.contains('"result"')
	assert response.contains('nesy_jsonrpc')
}

// Verify that a missing jsonrpc field returns an invalid request error.
fn test_jsonrpc_missing_version() {
	router := Router.new()
	request := '{"jsonrpc":"1.0","method":"nesy.health","params":{},"id":5}'
	response := router.dispatch(request)

	assert response.contains('"error"')
	assert response.contains('must be "2.0"')
}
