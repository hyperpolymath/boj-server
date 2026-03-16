// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Agent-MCP Cartridge — SOAP 1.2 adapter layer.
//
// Implements a SOAP 1.2 endpoint over HTTP that exposes the OODA loop
// FSM.  Requests and responses use XML envelopes with the Agent
// namespace (xmlns:agent="urn:agent-mcp:ooda").
//
// Operations:
//   CreateSession     — create a new OODA session
//   EndSession        — destroy a session (param: SessionId)
//   Transition        — move to a named state (params: SessionId, State)
//   Advance           — move to next OODA step (param: SessionId)
//   Halt              — halt a session (param: SessionId)
//   GetStatus         — query session state (param: SessionId)
//   ValidateOODA      — check transition legality (params: From, To)
//   ToolCallInfo      — tool-call metadata (param: Kind)
//   SafetyCheckInfo   — safety-check metadata (param: Outcome)
//
// All responses are wrapped in a SOAP 1.2 Envelope > Body structure.
// Errors use SOAP Fault elements.

module agent_soap

import json
import net.http
import encoding.xml

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
// XML Constants — SOAP 1.2 namespace and Agent namespace URIs.
// ═══════════════════════════════════════════════════════════════════════

const soap_ns  = 'http://www.w3.org/2003/05/soap-envelope'
const agent_ns = 'urn:agent-mcp:ooda'

// ═══════════════════════════════════════════════════════════════════════
// XML Builders — construct SOAP 1.2 envelopes as raw XML strings.
// String concatenation is used rather than a DOM builder to keep the
// implementation self-contained and avoid external XML dependencies.
// ═══════════════════════════════════════════════════════════════════════

// soap_envelope wraps inner XML in a SOAP 1.2 Envelope > Body.
fn soap_envelope(inner string) string {
	return '<?xml version="1.0" encoding="UTF-8"?>\n' +
		'<soap:Envelope xmlns:soap="${soap_ns}" xmlns:agent="${agent_ns}">\n' +
		'  <soap:Body>\n' +
		'    ${inner}\n' +
		'  </soap:Body>\n' +
		'</soap:Envelope>'
}

// soap_fault wraps an error message in a SOAP 1.2 Fault element.
fn soap_fault(code string, reason string) string {
	inner := '<soap:Fault>\n' +
		'      <soap:Code><soap:Value>soap:${code}</soap:Value></soap:Code>\n' +
		'      <soap:Reason><soap:Text xml:lang="en">${reason}</soap:Text></soap:Reason>\n' +
		'    </soap:Fault>'
	return soap_envelope(inner)
}

// ═══════════════════════════════════════════════════════════════════════
// XML Parsing Helpers — extract element text from simple XML payloads.
// Uses basic string matching rather than a full XML parser.
// ═══════════════════════════════════════════════════════════════════════

// extract_element finds the text content of <tag>...</tag> in raw XML.
// Returns an error if the tag is not found.
fn extract_element(raw string, tag string) !string {
	open := '<${tag}>'
	close := '</${tag}>'
	start := raw.index(open) or { return error('missing element: ${tag}') }
	end := raw.index(close) or { return error('missing closing: ${tag}') }
	return raw[start + open.len..end].trim_space()
}

// extract_soap_action reads the SOAPAction header or, if absent, tries
// to find the first agent-namespaced element name inside the Body.
fn extract_soap_action(req_body string) !string {
	// Try to find an agent: prefixed element inside the body.
	// Pattern: <agent:OperationName ...>
	idx := req_body.index('<agent:') or {
		return error('no agent operation found in SOAP body')
	}
	rest := req_body[idx + 7..] // skip "<agent:"
	end := rest.index_any('> /') or {
		return error('malformed agent element')
	}
	return rest[..end]
}

// ═══════════════════════════════════════════════════════════════════════
// Operation Handlers — one function per SOAP operation.
// ═══════════════════════════════════════════════════════════════════════

// op_create_session creates a new OODA session.  No parameters.
fn op_create_session() string {
	idx := C.agent_new_session()
	if idx < 0 {
		return soap_fault('Receiver', 'no session slots available')
	}
	inner := '<agent:CreateSessionResponse>\n' +
		'      <agent:SessionId>${idx}</agent:SessionId>\n' +
		'      <agent:State>observe</agent:State>\n' +
		'      <agent:LoopCount>0</agent:LoopCount>\n' +
		'    </agent:CreateSessionResponse>'
	return soap_envelope(inner)
}

// op_end_session destroys the session given by <agent:SessionId>.
fn op_end_session(body string) string {
	id_str := extract_element(body, 'agent:SessionId') or {
		return soap_fault('Sender', 'missing SessionId element')
	}
	idx := id_str.int()
	result := C.agent_end_session(idx)
	if result != 0 {
		return soap_fault('Receiver', 'failed to end session ${idx}')
	}
	inner := '<agent:EndSessionResponse>\n' +
		'      <agent:Message>session ${idx} ended</agent:Message>\n' +
		'    </agent:EndSessionResponse>'
	return soap_envelope(inner)
}

// op_transition moves a session to the state given by <agent:State>.
fn op_transition(body string) string {
	id_str := extract_element(body, 'agent:SessionId') or {
		return soap_fault('Sender', 'missing SessionId element')
	}
	state_name := extract_element(body, 'agent:State') or {
		return soap_fault('Sender', 'missing State element')
	}
	idx := id_str.int()
	target := state_from_name(state_name) or {
		return soap_fault('Sender', err.msg())
	}
	current := C.agent_state(idx)
	if current < 0 {
		return soap_fault('Receiver', 'session ${idx} not found')
	}
	result := C.agent_transition(idx, target)
	if result < 0 {
		return soap_fault('Receiver', 'invalid transition from ${state_label(current)} to ${state_name}')
	}
	next := C.agent_next_state(target)
	inner := '<agent:TransitionResponse>\n' +
		'      <agent:SessionId>${idx}</agent:SessionId>\n' +
		'      <agent:From>${state_label(current)}</agent:From>\n' +
		'      <agent:To>${state_name}</agent:To>\n' +
		'      <agent:Success>true</agent:Success>\n' +
		'      <agent:NextState>${state_label(next)}</agent:NextState>\n' +
		'    </agent:TransitionResponse>'
	return soap_envelope(inner)
}

// op_advance moves the session to the next OODA step.
fn op_advance(body string) string {
	id_str := extract_element(body, 'agent:SessionId') or {
		return soap_fault('Sender', 'missing SessionId element')
	}
	idx := id_str.int()
	current := C.agent_state(idx)
	if current < 0 {
		return soap_fault('Receiver', 'session ${idx} not found')
	}
	next := C.agent_next_state(current)
	result := C.agent_transition(idx, next)
	if result < 0 {
		return soap_fault('Receiver', 'advance failed')
	}
	after_next := C.agent_next_state(next)
	inner := '<agent:AdvanceResponse>\n' +
		'      <agent:SessionId>${idx}</agent:SessionId>\n' +
		'      <agent:From>${state_label(current)}</agent:From>\n' +
		'      <agent:To>${state_label(next)}</agent:To>\n' +
		'      <agent:Success>true</agent:Success>\n' +
		'      <agent:NextState>${state_label(after_next)}</agent:NextState>\n' +
		'    </agent:AdvanceResponse>'
	return soap_envelope(inner)
}

// op_halt halts the session immediately (transition to state 5).
fn op_halt(body string) string {
	id_str := extract_element(body, 'agent:SessionId') or {
		return soap_fault('Sender', 'missing SessionId element')
	}
	idx := id_str.int()
	current := C.agent_state(idx)
	if current < 0 {
		return soap_fault('Receiver', 'session ${idx} not found')
	}
	result := C.agent_transition(idx, 5) // 5 = halted
	if result < 0 {
		return soap_fault('Receiver', 'halt failed')
	}
	inner := '<agent:HaltResponse>\n' +
		'      <agent:SessionId>${idx}</agent:SessionId>\n' +
		'      <agent:State>halted</agent:State>\n' +
		'      <agent:LoopCount>${C.agent_loop_count(idx)}</agent:LoopCount>\n' +
		'    </agent:HaltResponse>'
	return soap_envelope(inner)
}

// op_get_status returns the current state of the session.
fn op_get_status(body string) string {
	id_str := extract_element(body, 'agent:SessionId') or {
		return soap_fault('Sender', 'missing SessionId element')
	}
	idx := id_str.int()
	s := C.agent_state(idx)
	if s < 0 {
		return soap_fault('Receiver', 'session ${idx} not found')
	}
	inner := '<agent:GetStatusResponse>\n' +
		'      <agent:SessionId>${idx}</agent:SessionId>\n' +
		'      <agent:State>${state_label(s)}</agent:State>\n' +
		'      <agent:LoopCount>${C.agent_loop_count(idx)}</agent:LoopCount>\n' +
		'    </agent:GetStatusResponse>'
	return soap_envelope(inner)
}

// op_validate_ooda checks whether a transition from <agent:From> to
// <agent:To> is legal according to the OODA FSM rules.
fn op_validate_ooda(body string) string {
	from_name := extract_element(body, 'agent:From') or {
		return soap_fault('Sender', 'missing From element')
	}
	to_name := extract_element(body, 'agent:To') or {
		return soap_fault('Sender', 'missing To element')
	}
	from_int := state_from_name(from_name) or {
		return soap_fault('Sender', err.msg())
	}
	to_int := state_from_name(to_name) or {
		return soap_fault('Sender', err.msg())
	}
	allowed := C.agent_validate_ooda(from_int, to_int) == 1
	inner := '<agent:ValidateOODAResponse>\n' +
		'      <agent:From>${from_name}</agent:From>\n' +
		'      <agent:To>${to_name}</agent:To>\n' +
		'      <agent:Allowed>${allowed}</agent:Allowed>\n' +
		'    </agent:ValidateOODAResponse>'
	return soap_envelope(inner)
}

// op_tool_call_info returns tool-call safety metadata for the given
// <agent:Kind>.
fn op_tool_call_info(body string) string {
	kind := extract_element(body, 'agent:Kind') or {
		return soap_fault('Sender', 'missing Kind element')
	}
	tc := match kind.to_lower() {
		'execute' { 0 }
		'query' { 1 }
		'transform' { 2 }
		'communicate' { 3 }
		'delegate' { 4 }
		'escalate' { 5 }
		else { return soap_fault('Sender', 'unknown tool call: ${kind}') }
	}
	has_side := C.agent_tool_has_side_effects(tc) == 1
	needs_safety := C.agent_tool_requires_safety(tc) == 1
	inner := '<agent:ToolCallInfoResponse>\n' +
		'      <agent:Kind>${tool_call_label(tc)}</agent:Kind>\n' +
		'      <agent:HasSideEffects>${has_side}</agent:HasSideEffects>\n' +
		'      <agent:RequiresSafetyCheck>${needs_safety}</agent:RequiresSafetyCheck>\n' +
		'    </agent:ToolCallInfoResponse>'
	return soap_envelope(inner)
}

// op_safety_check_info returns safety-check metadata for the given
// <agent:Outcome>.
fn op_safety_check_info(body string) string {
	outcome := extract_element(body, 'agent:Outcome') or {
		return soap_fault('Sender', 'missing Outcome element')
	}
	sc := match outcome.to_lower() {
		'approved' { 0 }
		'denied' { 1 }
		'escalated' { 2 }
		'timeout' { 3 }
		'sandboxed' { 4 }
		'humanrequired', 'human_required' { 5 }
		else { return soap_fault('Sender', 'unknown safety check: ${outcome}') }
	}
	allows := C.agent_safety_allows_exec(sc) == 1
	needs_human := C.agent_safety_needs_human(sc) == 1
	inner := '<agent:SafetyCheckInfoResponse>\n' +
		'      <agent:Outcome>${safety_check_label(sc)}</agent:Outcome>\n' +
		'      <agent:AllowsExecution>${allows}</agent:AllowsExecution>\n' +
		'      <agent:NeedsHuman>${needs_human}</agent:NeedsHuman>\n' +
		'    </agent:SafetyCheckInfoResponse>'
	return soap_envelope(inner)
}

// ═══════════════════════════════════════════════════════════════════════
// SOAP Dispatcher — routes incoming SOAP bodies to operation handlers.
// ═══════════════════════════════════════════════════════════════════════

// dispatch_soap parses the SOAP body to determine the operation and
// calls the appropriate handler.  Returns the full SOAP response XML.
pub fn dispatch_soap(body string) string {
	action := extract_soap_action(body) or {
		return soap_fault('Sender', 'cannot determine SOAP action: ${err}')
	}
	return match action {
		'CreateSession' { op_create_session() }
		'EndSession' { op_end_session(body) }
		'Transition' { op_transition(body) }
		'Advance' { op_advance(body) }
		'Halt' { op_halt(body) }
		'GetStatus' { op_get_status(body) }
		'ValidateOODA' { op_validate_ooda(body) }
		'ToolCallInfo' { op_tool_call_info(body) }
		'SafetyCheckInfo' { op_safety_check_info(body) }
		else { soap_fault('Sender', 'unknown operation: ${action}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// HTTP Server — serves SOAP 1.2 over a single POST endpoint.
// ═══════════════════════════════════════════════════════════════════════

// SoapHandler implements http.Handler.  Accepts POST requests with
// Content-Type: application/soap+xml and routes them through
// dispatch_soap.
struct SoapHandler {}

fn (h SoapHandler) handle(req http.Request) http.Response {
	if req.method != .post {
		return http.Response{
			status_code: 405
			body: soap_fault('Sender', 'method not allowed — use POST')
			header: http.new_header_from_map({
				'Content-Type': 'application/soap+xml; charset=utf-8'
			})
		}
	}
	result := dispatch_soap(req.data)
	return http.Response{
		status_code: 200
		body: result
		header: http.new_header_from_map({
			'Content-Type': 'application/soap+xml; charset=utf-8'
		})
	}
}

// start_soap_server launches an HTTP server that accepts SOAP 1.2
// requests at the root path.
pub fn start_soap_server(port int) ! {
	mut server := http.Server{
		port: port
		handler: SoapHandler{}
	}
	server.listen_and_serve()
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// test_dispatch_create_session verifies that a CreateSession SOAP
// request returns a valid envelope with a session id and "observe" state.
fn test_dispatch_create_session() {
	body := '<?xml version="1.0"?>\n' +
		'<soap:Envelope xmlns:soap="${soap_ns}" xmlns:agent="${agent_ns}">\n' +
		'  <soap:Body>\n' +
		'    <agent:CreateSession/>\n' +
		'  </soap:Body>\n' +
		'</soap:Envelope>'
	result := dispatch_soap(body)
	// The response must contain a CreateSessionResponse with State=observe.
	assert result.contains('CreateSessionResponse')
	assert result.contains('<agent:State>observe</agent:State>')
}

// test_dispatch_unknown_operation verifies that an unrecognised operation
// returns a SOAP Fault.
fn test_dispatch_unknown_operation() {
	body := '<soap:Envelope xmlns:soap="${soap_ns}" xmlns:agent="${agent_ns}">' +
		'<soap:Body><agent:DoSomethingWeird/></soap:Body></soap:Envelope>'
	result := dispatch_soap(body)
	assert result.contains('soap:Fault')
	assert result.contains('unknown operation')
}

// test_extract_element verifies the simple XML element extractor.
fn test_extract_element() {
	xml_str := '<agent:SessionId>42</agent:SessionId>'
	val := extract_element(xml_str, 'agent:SessionId') or {
		assert false, 'extraction failed'
		return
	}
	assert val == '42'
}
