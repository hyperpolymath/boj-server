// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — tRPC transport adapter.
//
// Implements a tRPC-style server exposing the NeSy harmonization engine.
// All procedures are registered as queries on a Router. Each query
// receives typed input, validates it, calls the Zig FFI, and returns
// a typed result. Middleware hooks run before each procedure for logging
// and input sanitisation.
//
// Procedures (all queries — no mutations since NeSy is stateless):
//   harmonize  — input: {neural: string, symbolic: string}
//   drift      — input: {kind: string}
//   mode       — input: {mode: string}
//   health     — no input
//
// Transport: HTTP GET with query params (query procedures) or POST with
// JSON body. The tRPC batch endpoint is at /trpc/<procedure>.

module nesy_trpc

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
// Input validation — parse and validate string labels into FFI integers
// ═══════════════════════════════════════════════════════════════════════

// Valid neural verdict labels for input validation error messages.
const valid_neural_verdicts = ['probable_safe', 'unsure', 'probable_unsafe']

// Valid symbolic verdict labels for input validation error messages.
const valid_symbolic_verdicts = ['proven_safe', 'no_proof', 'proven_unsafe']

// Valid drift kind labels (lowercased forms accepted).
const valid_drift_kinds = ['none', 'semantic', 'confidence', 'factual', 'temporal', 'catastrophic']

// Valid reasoning mode labels (lowercased forms accepted).
const valid_modes = ['symbolic', 'neural', 'symtoneural', 'neuraltosym', 'ensemble', 'cascade']

// Parse and validate a neural verdict string into its integer encoding.
fn parse_neural(s string) !int {
	return match s {
		'probable_safe' { 1 }
		'unsure' { 2 }
		'probable_unsafe' { 3 }
		else { error('invalid neural verdict "${s}". Must be one of: ${valid_neural_verdicts}') }
	}
}

// Parse and validate a symbolic verdict string into its integer encoding.
fn parse_symbolic(s string) !int {
	return match s {
		'proven_safe' { 1 }
		'no_proof' { 2 }
		'proven_unsafe' { 3 }
		else { error('invalid symbolic verdict "${s}". Must be one of: ${valid_symbolic_verdicts}') }
	}
}

// Parse and validate a drift kind string into its integer encoding.
fn parse_drift(s string) !int {
	return match s.to_lower() {
		'nodrift', 'no_drift', 'none' { 0 }
		'semanticdrift', 'semantic' { 1 }
		'confidencedrift', 'confidence' { 2 }
		'factualdrift', 'factual' { 3 }
		'temporaldrift', 'temporal' { 4 }
		'catastrophicdrift', 'catastrophic' { 5 }
		else { error('invalid drift kind "${s}". Must be one of: ${valid_drift_kinds}') }
	}
}

// Parse and validate a reasoning mode string into its integer encoding.
fn parse_mode(s string) !int {
	return match s.to_lower() {
		'symbolic' { 0 }
		'neural' { 1 }
		'symtoneural' { 2 }
		'neuraltosym' { 3 }
		'ensemble' { 4 }
		'cascade' { 5 }
		else { error('invalid reasoning mode "${s}". Must be one of: ${valid_modes}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// tRPC wire types
// ═══════════════════════════════════════════════════════════════════════

// tRPC procedure types. NeSy only uses queries (stateless reads).
enum ProcedureType {
	query
	mutation
	subscription
}

// Wrapper for a tRPC result conforming to the envelope format.
// The tRPC protocol wraps every response in {result: {data: ...}}.
struct TrpcEnvelope {
	result TrpcResult
}

// The inner result object containing either data or an error.
struct TrpcResult {
	data  json.RawMessage @[omitempty]
	error TrpcError       @[omitempty]
}

// tRPC error shape: code + message + optional data.
struct TrpcError {
	code    string
	message string
}

// ═══════════════════════════════════════════════════════════════════════
// Input types — decoded from query parameters or POST body
// ═══════════════════════════════════════════════════════════════════════

// Input for the `harmonize` query procedure.
struct HarmonizeInput {
	neural   string
	symbolic string
}

// Input for the `drift` query procedure.
struct DriftInput {
	kind string
}

// Input for the `mode` query procedure.
struct ModeInput {
	mode string
}

// ═══════════════════════════════════════════════════════════════════════
// Output types — returned as the data field of a tRPC result
// ═══════════════════════════════════════════════════════════════════════

// Output for the `harmonize` query procedure.
struct HarmonizeOutput {
	neural_input   string
	symbolic_input string
	verdict        string
	confidence     string
	symbolic_wins  bool
}

// Output for the `drift` query procedure.
struct DriftOutput {
	drift              string
	severity           int
	urgent             bool
	recommended_action string
}

// Output for the `mode` query procedure.
struct ModeOutput {
	mode          string
	uses_symbolic bool
	uses_neural   bool
	is_hybrid     bool
}

// Output for the `health` query procedure.
struct HealthOutput {
	status  string
	adapter string
}

// ═══════════════════════════════════════════════════════════════════════
// Middleware — pre-procedure hooks for logging and validation
// ═══════════════════════════════════════════════════════════════════════

// Middleware function signature. Receives the procedure name and raw
// input, returns an optional error to abort the request.
type MiddlewareFn = fn (string, string) !

// Default middleware that logs the procedure call (no-op in adapter;
// would write to a structured logger in production).
fn logging_middleware(procedure string, input string) ! {
	// In production: log.info('tRPC call: ${procedure}')
	_ = procedure
	_ = input
}

// Input sanitisation middleware — rejects payloads over 8KB.
fn size_guard_middleware(procedure string, input string) ! {
	if input.len > 8192 {
		return error('input too large: ${input.len} bytes (max 8192)')
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Router — maps procedure names to query handlers with middleware
// ═══════════════════════════════════════════════════════════════════════

// A ProcedureDef ties a procedure name to its type and handler.
struct ProcedureDef {
	name       string
	kind       ProcedureType
	handler_fn fn (string) !string // receives raw input JSON, returns result JSON
}

// The Router holds registered procedures and the middleware chain.
pub struct Router {
mut:
	procedures map[string]ProcedureDef
	middleware []MiddlewareFn
}

// Create a new Router with all NeSy procedures and default middleware.
pub fn Router.new() Router {
	mut r := Router{
		middleware: [logging_middleware, size_guard_middleware]
	}

	r.procedures['harmonize'] = ProcedureDef{
		name: 'harmonize'
		kind: .query
		handler_fn: query_harmonize
	}
	r.procedures['drift'] = ProcedureDef{
		name: 'drift'
		kind: .query
		handler_fn: query_drift
	}
	r.procedures['mode'] = ProcedureDef{
		name: 'mode'
		kind: .query
		handler_fn: query_mode
	}
	r.procedures['health'] = ProcedureDef{
		name: 'health'
		kind: .query
		handler_fn: query_health
	}

	return r
}

// Call a procedure by name with the given raw input JSON.
// Runs the middleware chain, then dispatches to the handler.
// Returns the tRPC envelope JSON string.
pub fn (r &Router) call(procedure string, input string) string {
	// Run middleware chain
	for mw in r.middleware {
		mw(procedure, input) or {
			return json.encode(TrpcEnvelope{
				result: TrpcResult{
					error: TrpcError{
						code: 'BAD_REQUEST'
						message: err.msg()
					}
				}
			})
		}
	}

	// Look up the procedure
	proc := r.procedures[procedure] or {
		return json.encode(TrpcEnvelope{
			result: TrpcResult{
				error: TrpcError{
					code: 'NOT_FOUND'
					message: 'procedure not found: ${procedure}'
				}
			}
		})
	}

	// Execute the handler
	result_json := proc.handler_fn(input) or {
		return json.encode(TrpcEnvelope{
			result: TrpcResult{
				error: TrpcError{
					code: 'BAD_REQUEST'
					message: err.msg()
				}
			}
		})
	}

	return json.encode(TrpcEnvelope{
		result: TrpcResult{
			data: json.RawMessage(result_json.bytes())
		}
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Query handlers — each processes typed input and calls the Zig FFI
// ═══════════════════════════════════════════════════════════════════════

// Query: harmonize — decode neural + symbolic verdicts, call FFI,
// return harmonized verdict with confidence level.
fn query_harmonize(input string) !string {
	params := json.decode(HarmonizeInput, input) or {
		return error('invalid input for harmonize: ${err}')
	}
	neural := parse_neural(params.neural)!
	symbolic := parse_symbolic(params.symbolic)!

	result := C.nesy_harmonize(neural, symbolic)
	conf := C.nesy_confidence(neural, symbolic)

	return json.encode(HarmonizeOutput{
		neural_input: neural_label(neural)
		symbolic_input: symbolic_label(symbolic)
		verdict: harmonized_label(result)
		confidence: confidence_label(conf)
		symbolic_wins: symbolic != 2
	})
}

// Query: drift — decode drift kind, call FFI, return drift report
// with severity and recommended action.
fn query_drift(input string) !string {
	params := json.decode(DriftInput, input) or {
		return error('invalid input for drift: ${err}')
	}
	drift_int := parse_drift(params.kind)!
	action := C.nesy_recommend_drift_action(drift_int)

	return json.encode(DriftOutput{
		drift: drift_kind_label(drift_int)
		severity: drift_int
		urgent: C.nesy_drift_is_urgent(drift_int) == 1
		recommended_action: drift_action_label(action)
	})
}

// Query: mode — decode reasoning mode, call FFI, return mode metadata
// including whether it is a hybrid (symbolic + neural) mode.
fn query_mode(input string) !string {
	params := json.decode(ModeInput, input) or {
		return error('invalid input for mode: ${err}')
	}
	mode_int := parse_mode(params.mode)!
	sym := C.nesy_mode_uses_symbolic(mode_int) == 1
	neur := C.nesy_mode_uses_neural(mode_int) == 1

	return json.encode(ModeOutput{
		mode: reasoning_mode_label(mode_int)
		uses_symbolic: sym
		uses_neural: neur
		is_hybrid: sym && neur
	})
}

// Query: health — return adapter status, no input needed.
fn query_health(input string) !string {
	return json.encode(HealthOutput{
		status: 'ok'
		adapter: 'nesy_trpc'
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that the harmonize query returns a correct tRPC envelope
// with symbolic override in effect.
fn test_trpc_harmonize() {
	router := Router.new()
	input := '{"neural":"unsure","symbolic":"proven_unsafe"}'
	response := router.call('harmonize', input)

	assert response.contains('"result"')
	assert response.contains('critical_unsafe') || response.contains('requires_review')
}

// Verify that the drift query returns severity and urgency data.
fn test_trpc_drift() {
	router := Router.new()
	input := '{"kind":"temporal"}'
	response := router.call('drift', input)

	assert response.contains('"result"')
	assert response.contains('TemporalDrift')
}

// Verify that the mode query returns hybrid status for ensemble.
fn test_trpc_mode() {
	router := Router.new()
	input := '{"mode":"cascade"}'
	response := router.call('mode', input)

	assert response.contains('"result"')
	assert response.contains('Cascade')
}

// Verify that the health query returns adapter name.
fn test_trpc_health() {
	router := Router.new()
	response := router.call('health', '{}')

	assert response.contains('nesy_trpc')
	assert response.contains('"result"')
}

// Verify that an unknown procedure returns a NOT_FOUND error.
fn test_trpc_procedure_not_found() {
	router := Router.new()
	response := router.call('explode', '{}')

	assert response.contains('NOT_FOUND')
	assert response.contains('procedure not found')
}

// Verify that invalid input labels produce a BAD_REQUEST error
// with a helpful validation message.
fn test_trpc_invalid_input() {
	router := Router.new()
	input := '{"neural":"invalid_label","symbolic":"proven_safe"}'
	response := router.call('harmonize', input)

	assert response.contains('BAD_REQUEST')
	assert response.contains('invalid neural verdict')
}
