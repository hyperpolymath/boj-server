// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Agent-MCP Cartridge — JSON-RPC 2.0 adapter layer.
//
// Implements a JSON-RPC 2.0 server over HTTP that exposes the OODA loop
// FSM.  Every request is a standard JSON-RPC envelope with "jsonrpc",
// "method", "params", and "id" fields.  Responses include "result" or
// "error" per the JSON-RPC 2.0 specification (https://www.jsonrpc.org/).
//
// Methods:
//   agent.newSession()                    — create a new OODA session
//   agent.endSession({id})               — destroy a session
//   agent.transition({id, state})         — move to a named state
//   agent.advance({id})                   — move to the next OODA step
//   agent.halt({id})                      — immediately halt a session
//   agent.status({id})                    — query current session state
//   agent.validate({from, to})            — check if a transition is legal
//   agent.toolInfo({kind})                — tool-call safety metadata
//   agent.safetyInfo({outcome})           — safety-check metadata
//   agent.health()                        — server liveness probe

module agent_jsonrpc

import json
import net.http

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against agent_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.agent_new_session() int
fn C.agent_end_session(idx int) int
fn C.agent_transition(idx int, to int) int
fn C.agent_state(idx int) int
fn C.agent_loop_count(idx int) int
fn C.agent_validate_ooda(from int, to int) int
fn C.agent_next_state(current int) int
fn C.agent_reset()
// Protocol FFI (v0.2.0 — from proven-agentic)
fn C.agent_tool_has_side_effects(tc int) int
fn C.agent_tool_requires_safety(tc int) int
fn C.agent_safety_allows_exec(sc int) int
fn C.agent_safety_needs_human(sc int) int
fn C.agent_coordination_is_multi(c int) int
fn C.agent_memory_is_persistent(m int) int

// ═══════════════════════════════════════════════════════════════════════
// Label helpers — identical to agent_adapter.v for self-containment.
// ═══════════════════════════════════════════════════════════════════════

// state_label converts an AgentState integer (1–5) to its OODA name.
fn state_label(s int) string {
	return match s {
		1 { 'observe' }
		2 { 'orient' }
		3 { 'decide' }
		4 { 'act' }
		5 { 'halted' }
		else { 'unknown' }
	}
}

// state_from_name converts a state name back to its integer encoding.
fn state_from_name(name string) !int {
	return match name {
		'observe' { 1 }
		'orient' { 2 }
		'decide' { 3 }
		'act' { 4 }
		'halted' { 5 }
		else { return error('unknown state: ${name}') }
	}
}

// tool_call_label converts a ToolCall integer (0–5) to its name.
fn tool_call_label(t int) string {
	return match t {
		0 { 'Execute' }
		1 { 'Query' }
		2 { 'Transform' }
		3 { 'Communicate' }
		4 { 'Delegate' }
		5 { 'Escalate' }
		else { 'Unknown' }
	}
}

// safety_check_label converts a SafetyCheck integer (0–5) to its name.
fn safety_check_label(s int) string {
	return match s {
		0 { 'Approved' }
		1 { 'Denied' }
		2 { 'Escalated' }
		3 { 'Timeout' }
		4 { 'Sandboxed' }
		5 { 'HumanRequired' }
		else { 'Unknown' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// JSON-RPC 2.0 Envelope Types
// ═══════════════════════════════════════════════════════════════════════

// JsonRpcRequest is the inbound request envelope per JSON-RPC 2.0.
struct JsonRpcRequest {
	jsonrpc string            @[json: 'jsonrpc']
	method  string            @[json: 'method']
	params  map[string]string @[json: 'params']
	id      int               @[json: 'id']
}

// JsonRpcResponse is the outbound response envelope.  Exactly one of
// `result` or `error` will be populated.
struct JsonRpcResponse {
	jsonrpc string         @[json: 'jsonrpc']
	id      int            @[json: 'id']
	result  string         @[json: 'result'; omitempty]
	error   JsonRpcError   @[json: 'error'; omitempty]
}

// JsonRpcError carries a machine-readable code and a human message.
struct JsonRpcError {
	code    int    @[json: 'code']
	message string @[json: 'message']
}

// ═══════════════════════════════════════════════════════════════════════
// Result payload types — nested inside the "result" field.
// ═══════════════════════════════════════════════════════════════════════

// SessionResult holds a session snapshot.
struct SessionResult {
	session_id int
	state      string
	loop_count int
}

// TransitionResult holds the outcome of a state transition.
struct TransitionResult {
	session_id int
	from       string
	to         string
	success    bool
	next_state string
}

// ValidationResult holds the outcome of a transition validity check.
struct ValidationResult {
	from    string
	to      string
	allowed bool
}

// ToolInfoResult holds tool-call safety metadata.
struct ToolInfoResult {
	kind                  string
	has_side_effects      bool
	requires_safety_check bool
}

// SafetyInfoResult holds safety-check metadata.
struct SafetyInfoResult {
	outcome          string
	allows_execution bool
	needs_human      bool
}

// HealthResult holds the liveness probe response.
struct HealthResult {
	status   string
	protocol string
}

// ═══════════════════════════════════════════════════════════════════════
// Standard JSON-RPC 2.0 error codes
// ═══════════════════════════════════════════════════════════════════════

const parse_error      = -32700
const invalid_request  = -32600
const method_not_found = -32601
const invalid_params   = -32602
const internal_error   = -32603

// ═══════════════════════════════════════════════════════════════════════
// Helpers — build success / error envelopes
// ═══════════════════════════════════════════════════════════════════════

// ok_response wraps a result payload in a JSON-RPC 2.0 success envelope.
fn ok_response(id int, result string) string {
	return json.encode(JsonRpcResponse{
		jsonrpc: '2.0'
		id: id
		result: result
	})
}

// err_response wraps an error code and message in a JSON-RPC 2.0 error
// envelope.
fn err_response(id int, code int, message string) string {
	return json.encode(JsonRpcResponse{
		jsonrpc: '2.0'
		id: id
		error: JsonRpcError{ code: code, message: message }
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Dispatch — route a parsed request to the correct handler.
// ═══════════════════════════════════════════════════════════════════════

// dispatch processes a single JSON-RPC 2.0 request and returns the
// JSON-encoded response string.
pub fn dispatch(raw string) string {
	req := json.decode(JsonRpcRequest, raw) or {
		return err_response(0, parse_error, 'invalid JSON: ${err}')
	}

	if req.jsonrpc != '2.0' {
		return err_response(req.id, invalid_request, 'jsonrpc must be "2.0"')
	}

	return match req.method {
		'agent.newSession' { handle_new_session(req) }
		'agent.endSession' { handle_end_session(req) }
		'agent.transition' { handle_transition(req) }
		'agent.advance' { handle_advance(req) }
		'agent.halt' { handle_halt(req) }
		'agent.status' { handle_status(req) }
		'agent.validate' { handle_validate(req) }
		'agent.toolInfo' { handle_tool_info(req) }
		'agent.safetyInfo' { handle_safety_info(req) }
		'agent.health' { handle_health(req) }
		else { err_response(req.id, method_not_found, 'unknown method: ${req.method}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Method handlers — one function per JSON-RPC method.
// ═══════════════════════════════════════════════════════════════════════

// handle_new_session creates a new OODA session (no params required).
fn handle_new_session(req JsonRpcRequest) string {
	idx := C.agent_new_session()
	if idx < 0 {
		return err_response(req.id, internal_error, 'no session slots available')
	}
	return ok_response(req.id, json.encode(SessionResult{
		session_id: idx
		state: 'observe'
		loop_count: 0
	}))
}

// handle_end_session destroys the session identified by params.id.
fn handle_end_session(req JsonRpcRequest) string {
	id_str := req.params['id'] or {
		return err_response(req.id, invalid_params, 'missing param: id')
	}
	idx := id_str.int()
	result := C.agent_end_session(idx)
	if result != 0 {
		return err_response(req.id, internal_error, 'failed to end session ${idx}')
	}
	return ok_response(req.id, '"session ${idx} ended"')
}

// handle_transition moves the session to a named state (params: id, state).
fn handle_transition(req JsonRpcRequest) string {
	id_str := req.params['id'] or {
		return err_response(req.id, invalid_params, 'missing param: id')
	}
	state_name := req.params['state'] or {
		return err_response(req.id, invalid_params, 'missing param: state')
	}
	idx := id_str.int()
	target := state_from_name(state_name) or {
		return err_response(req.id, invalid_params, err.msg())
	}
	current := C.agent_state(idx)
	if current < 0 {
		return err_response(req.id, internal_error, 'session ${idx} not found')
	}
	result := C.agent_transition(idx, target)
	if result < 0 {
		return err_response(req.id, internal_error, 'invalid transition from ${state_label(current)} to ${state_name}')
	}
	return ok_response(req.id, json.encode(TransitionResult{
		session_id: idx
		from: state_label(current)
		to: state_name
		success: true
		next_state: state_label(C.agent_next_state(target))
	}))
}

// handle_advance moves the session to the next OODA step (params: id).
fn handle_advance(req JsonRpcRequest) string {
	id_str := req.params['id'] or {
		return err_response(req.id, invalid_params, 'missing param: id')
	}
	idx := id_str.int()
	current := C.agent_state(idx)
	if current < 0 {
		return err_response(req.id, internal_error, 'session ${idx} not found')
	}
	next := C.agent_next_state(current)
	result := C.agent_transition(idx, next)
	if result < 0 {
		return err_response(req.id, internal_error, 'advance failed')
	}
	return ok_response(req.id, json.encode(TransitionResult{
		session_id: idx
		from: state_label(current)
		to: state_label(next)
		success: true
		next_state: state_label(C.agent_next_state(next))
	}))
}

// handle_halt stops the session immediately (params: id).
fn handle_halt(req JsonRpcRequest) string {
	id_str := req.params['id'] or {
		return err_response(req.id, invalid_params, 'missing param: id')
	}
	idx := id_str.int()
	current := C.agent_state(idx)
	if current < 0 {
		return err_response(req.id, internal_error, 'session ${idx} not found')
	}
	result := C.agent_transition(idx, 5) // 5 = halted
	if result < 0 {
		return err_response(req.id, internal_error, 'halt failed')
	}
	return ok_response(req.id, json.encode(SessionResult{
		session_id: idx
		state: 'halted'
		loop_count: C.agent_loop_count(idx)
	}))
}

// handle_status returns the current state of a session (params: id).
fn handle_status(req JsonRpcRequest) string {
	id_str := req.params['id'] or {
		return err_response(req.id, invalid_params, 'missing param: id')
	}
	idx := id_str.int()
	s := C.agent_state(idx)
	if s < 0 {
		return err_response(req.id, internal_error, 'session ${idx} not found')
	}
	return ok_response(req.id, json.encode(SessionResult{
		session_id: idx
		state: state_label(s)
		loop_count: C.agent_loop_count(idx)
	}))
}

// handle_validate checks whether a proposed state transition is legal
// (params: from, to).
fn handle_validate(req JsonRpcRequest) string {
	from_name := req.params['from'] or {
		return err_response(req.id, invalid_params, 'missing param: from')
	}
	to_name := req.params['to'] or {
		return err_response(req.id, invalid_params, 'missing param: to')
	}
	from_int := state_from_name(from_name) or {
		return err_response(req.id, invalid_params, err.msg())
	}
	to_int := state_from_name(to_name) or {
		return err_response(req.id, invalid_params, err.msg())
	}
	allowed := C.agent_validate_ooda(from_int, to_int) == 1
	return ok_response(req.id, json.encode(ValidationResult{
		from: from_name
		to: to_name
		allowed: allowed
	}))
}

// handle_tool_info returns tool-call safety metadata (params: kind).
fn handle_tool_info(req JsonRpcRequest) string {
	kind := req.params['kind'] or {
		return err_response(req.id, invalid_params, 'missing param: kind')
	}
	tc := match kind.to_lower() {
		'execute' { 0 }
		'query' { 1 }
		'transform' { 2 }
		'communicate' { 3 }
		'delegate' { 4 }
		'escalate' { 5 }
		else { return err_response(req.id, invalid_params, 'unknown tool call: ${kind}') }
	}
	return ok_response(req.id, json.encode(ToolInfoResult{
		kind: tool_call_label(tc)
		has_side_effects: C.agent_tool_has_side_effects(tc) == 1
		requires_safety_check: C.agent_tool_requires_safety(tc) == 1
	}))
}

// handle_safety_info returns safety-check metadata (params: outcome).
fn handle_safety_info(req JsonRpcRequest) string {
	outcome := req.params['outcome'] or {
		return err_response(req.id, invalid_params, 'missing param: outcome')
	}
	sc := match outcome.to_lower() {
		'approved' { 0 }
		'denied' { 1 }
		'escalated' { 2 }
		'timeout' { 3 }
		'sandboxed' { 4 }
		'humanrequired', 'human_required' { 5 }
		else { return err_response(req.id, invalid_params, 'unknown safety check: ${outcome}') }
	}
	return ok_response(req.id, json.encode(SafetyInfoResult{
		outcome: safety_check_label(sc)
		allows_execution: C.agent_safety_allows_exec(sc) == 1
		needs_human: C.agent_safety_needs_human(sc) == 1
	}))
}

// handle_health returns a simple liveness status (no params).
fn handle_health(req JsonRpcRequest) string {
	return ok_response(req.id, json.encode(HealthResult{
		status: 'ok'
		protocol: 'json-rpc-2.0'
	}))
}

// ═══════════════════════════════════════════════════════════════════════
// HTTP Server — serves JSON-RPC 2.0 over a single POST endpoint.
// ═══════════════════════════════════════════════════════════════════════

// start_jsonrpc_server launches an HTTP server that accepts JSON-RPC
// 2.0 requests at the root path (POST /).
pub fn start_jsonrpc_server(port int) ! {
	mut server := http.Server{
		port: port
		handler: JsonRpcHandler{}
	}
	server.listen_and_serve()
}

// JsonRpcHandler implements http.Handler, forwarding every POST body
// through the dispatch function.
struct JsonRpcHandler {}

fn (h JsonRpcHandler) handle(req http.Request) http.Response {
	if req.method != .post {
		return http.Response{
			status_code: 405
			body: '{"error":"method not allowed — use POST"}'
			header: http.new_header_from_map({
				'Content-Type': 'application/json'
			})
		}
	}
	body := dispatch(req.data)
	return http.Response{
		status_code: 200
		body: body
		header: http.new_header_from_map({
			'Content-Type': 'application/json'
		})
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// test_dispatch_health verifies that the agent.health method returns a
// well-formed JSON-RPC 2.0 response with status "ok".
fn test_dispatch_health() {
	raw := '{"jsonrpc":"2.0","method":"agent.health","params":{},"id":1}'
	resp := dispatch(raw)
	decoded := json.decode(JsonRpcResponse, resp) or {
		assert false, 'failed to decode JSON-RPC response'
		return
	}
	assert decoded.jsonrpc == '2.0'
	assert decoded.id == 1
	assert decoded.result.len > 0

	inner := json.decode(HealthResult, decoded.result) or {
		assert false, 'failed to decode health result'
		return
	}
	assert inner.status == 'ok'
	assert inner.protocol == 'json-rpc-2.0'
}

// test_dispatch_unknown_method verifies that an unknown method returns
// the standard JSON-RPC method_not_found error code (-32601).
fn test_dispatch_unknown_method() {
	raw := '{"jsonrpc":"2.0","method":"agent.nope","params":{},"id":42}'
	resp := dispatch(raw)
	decoded := json.decode(JsonRpcResponse, resp) or {
		assert false, 'failed to decode JSON-RPC response'
		return
	}
	assert decoded.error.code == -32601
}
