// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — GraphQL transport adapter.
//
// Implements a GraphQL server exposing the ECHIDNA frontier LLM tactic
// advisory as a typed schema. This enables frontend proof dashboards to
// query exactly the fields they need, with introspection support.
//
// Schema:
//   type Query {
//     status: SessionStatus!
//     health: HealthInfo!
//   }
//   type Mutation {
//     suggestTactics(input: SuggestTacticsInput!): TacticResult!
//     rankProvers(input: RankProversInput!): RankerResult!
//     authenticate(input: AuthInput!): AuthResult!
//     closeSession: CloseResult!
//   }
//
// All operations are advisory-only (proven in Idris2, enforced in Zig).
// Ephemeral session tokens provide transaction-based security.

module echidna_llm_graphql

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
		'haiku' { 0 }
		'opus' { 2 }
		else { 1 }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// GraphQL wire types
// ═══════════════════════════════════════════════════════════════════════

// Inbound GraphQL request (standard POST body).
struct GraphqlRequest {
	query          string
	operation_name string @[json: 'operationName'] // optional
	variables      json.RawMessage                  // optional
}

// Outbound GraphQL response envelope.
struct GraphqlResponse {
	data   json.RawMessage   @[omitempty]
	errors []GraphqlError     @[omitempty]
}

// A single GraphQL error.
struct GraphqlError {
	message string
	path    []string @[omitempty]
}

// ═══════════════════════════════════════════════════════════════════════
// Input types — decoded from GraphQL variables
// ═══════════════════════════════════════════════════════════════════════

// Input for suggestTactics mutation.
struct SuggestTacticsInput {
	goal       string
	hypotheses string
	prover_id  int    @[json: 'proverId']
	top_k      int    @[json: 'topK'] = 10
	model      string = 'sonnet'
}

// Input for rankProvers mutation.
struct RankProversInput {
	goal  string
	model string = 'sonnet'
}

// Input for authenticate mutation.
struct AuthInput {
	token     string
	max_calls int @[json: 'maxCalls'] = 100
	expiry_ms int @[json: 'expiryMs'] = 60000
}

// Variables wrapper — the "input" field from GraphQL variables.
struct InputVars {
	input json.RawMessage
}

// ═══════════════════════════════════════════════════════════════════════
// Result types — encoded into the "data" field of each response
// ═══════════════════════════════════════════════════════════════════════

// Result for suggestTactics mutation.
struct SuggestTacticsData {
	suggest_tactics TacticResult @[json: 'suggestTactics']
}

struct TacticResult {
	success bool
	data    string
}

// Result for rankProvers mutation.
struct RankProversData {
	rank_provers RankerResult @[json: 'rankProvers']
}

struct RankerResult {
	success bool
	data    string
}

// Result for authenticate mutation.
struct AuthenticateData {
	authenticate AuthResult
}

struct AuthResult {
	success   bool
	state     string
	max_calls int @[json: 'maxCalls']
	expiry_ms int @[json: 'expiryMs']
}

// Result for closeSession mutation.
struct CloseSessionData {
	close_session CloseResult @[json: 'closeSession']
}

struct CloseResult {
	success bool
	state   string
}

// Result for status query.
struct StatusData {
	status SessionStatus
}

struct SessionStatus {
	state         string
	session_valid bool @[json: 'sessionValid']
}

// Result for health query.
struct HealthData {
	health HealthInfo
}

struct HealthInfo {
	status  string
	adapter string
}

// ═══════════════════════════════════════════════════════════════════════
// Query/Mutation resolver — parses GraphQL operations and dispatches
// ═══════════════════════════════════════════════════════════════════════

// Resolve a GraphQL request and return the JSON response string.
// This is a simplified resolver that matches operation names from the
// query string. Full GraphQL parsing is handled by the orchestrator;
// this adapter handles the per-cartridge field resolution.
pub fn resolve(request string) string {
	req := json.decode(GraphqlRequest, request) or {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'failed to parse GraphQL request: ${err}' }]
		})
	}

	query := req.query.to_lower()

	// Route based on query content (simplified — full parser at orchestrator level)
	if query.contains('suggesttactics') {
		return resolve_suggest_tactics(req.variables)
	} else if query.contains('rankprovers') {
		return resolve_rank_provers(req.variables)
	} else if query.contains('authenticate') {
		return resolve_authenticate(req.variables)
	} else if query.contains('closesession') {
		return resolve_close()
	} else if query.contains('status') {
		return resolve_status()
	} else if query.contains('health') {
		return resolve_health()
	}

	return json.encode(GraphqlResponse{
		errors: [GraphqlError{ message: 'unknown operation in query' }]
	})
}

// Resolve suggestTactics mutation.
fn resolve_suggest_tactics(variables json.RawMessage) string {
	vars := json.decode(InputVars, variables.str()) or {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'missing input variable', path: ['suggestTactics'] }]
		})
	}
	input := json.decode(SuggestTacticsInput, vars.input.str()) or {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'invalid input: ${err}', path: ['suggestTactics'] }]
		})
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'session expired or call limit reached', path: ['suggestTactics'] }]
		})
	}

	model := model_from_string(input.model)
	hypotheses := if input.hypotheses.len > 0 { input.hypotheses } else { '[]' }

	result_ptr := C.echidna_llm_suggest_tactics(
		input.goal.str, input.goal.len,
		hypotheses.str, hypotheses.len,
		input.prover_id, input.top_k, model,
	)

	if result_ptr == unsafe { nil } {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'tactic suggestion failed', path: ['suggestTactics'] }]
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	data := json.encode(SuggestTacticsData{
		suggest_tactics: TacticResult{ success: true, data: result_str }
	})
	return json.encode(GraphqlResponse{
		data: json.RawMessage(data.bytes())
	})
}

// Resolve rankProvers mutation.
fn resolve_rank_provers(variables json.RawMessage) string {
	vars := json.decode(InputVars, variables.str()) or {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'missing input variable', path: ['rankProvers'] }]
		})
	}
	input := json.decode(RankProversInput, vars.input.str()) or {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'invalid input: ${err}', path: ['rankProvers'] }]
		})
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'session expired or call limit reached', path: ['rankProvers'] }]
		})
	}

	model := model_from_string(input.model)
	result_ptr := C.echidna_llm_rank_provers(input.goal.str, input.goal.len, model)

	if result_ptr == unsafe { nil } {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'prover ranking failed', path: ['rankProvers'] }]
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	data := json.encode(RankProversData{
		rank_provers: RankerResult{ success: true, data: result_str }
	})
	return json.encode(GraphqlResponse{
		data: json.RawMessage(data.bytes())
	})
}

// Resolve authenticate mutation.
fn resolve_authenticate(variables json.RawMessage) string {
	vars := json.decode(InputVars, variables.str()) or {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'missing input variable', path: ['authenticate'] }]
		})
	}
	input := json.decode(AuthInput, vars.input.str()) or {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'invalid input: ${err}', path: ['authenticate'] }]
		})
	}

	result := C.echidna_llm_authenticate(input.token.str, input.token.len, input.max_calls, input.expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: msg, path: ['authenticate'] }]
		})
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	data := json.encode(AuthenticateData{
		authenticate: AuthResult{
			success: true
			state: state_label(state)
			max_calls: input.max_calls
			expiry_ms: input.expiry_ms
		}
	})
	return json.encode(GraphqlResponse{
		data: json.RawMessage(data.bytes())
	})
}

// Resolve closeSession mutation.
fn resolve_close() string {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		return json.encode(GraphqlResponse{
			errors: [GraphqlError{ message: 'cannot close — no active session', path: ['closeSession'] }]
		})
	}

	data := json.encode(CloseSessionData{
		close_session: CloseResult{ success: true, state: state_label(state) }
	})
	return json.encode(GraphqlResponse{
		data: json.RawMessage(data.bytes())
	})
}

// Resolve status query.
fn resolve_status() string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	data := json.encode(StatusData{
		status: SessionStatus{ state: state_label(state), session_valid: valid }
	})
	return json.encode(GraphqlResponse{
		data: json.RawMessage(data.bytes())
	})
}

// Resolve health query.
fn resolve_health() string {
	data := json.encode(HealthData{
		health: HealthInfo{ status: 'ok', adapter: 'echidna_llm_graphql' }
	})
	return json.encode(GraphqlResponse{
		data: json.RawMessage(data.bytes())
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that a health query returns valid GraphQL response.
fn test_graphql_health() {
	request := '{"query":"{ health { status adapter } }"}'
	response := resolve(request)
	assert response.contains('echidna_llm_graphql')
	assert !response.contains('"errors"')
}

// Verify that a status query returns session state.
fn test_graphql_status() {
	request := '{"query":"{ status { state sessionValid } }"}'
	response := resolve(request)
	assert response.contains('UNAUTHENTICATED') || response.contains('AUTHENTICATED')
		|| response.contains('OPERATING') || response.contains('CLOSED')
}

// Verify that suggestTactics without a session returns a GraphQL error.
fn test_graphql_suggest_no_session() {
	request := '{"query":"mutation { suggestTactics(input: $input) { success data } }","variables":{"input":{"goal":"forall n, n + 0 = n","proverId":0}}}'
	response := resolve(request)
	assert response.contains('errors') || response.contains('session')
}

// Verify that an unknown operation returns an error.
fn test_graphql_unknown_operation() {
	request := '{"query":"{ unknownField }"}'
	response := resolve(request)
	assert response.contains('errors')
	assert response.contains('unknown operation')
}

// Verify that malformed JSON returns a parse error.
fn test_graphql_malformed() {
	request := '{"broken'
	response := resolve(request)
	assert response.contains('errors')
	assert response.contains('failed to parse')
}
