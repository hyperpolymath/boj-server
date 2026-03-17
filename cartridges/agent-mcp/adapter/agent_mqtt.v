// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Agent-MCP Cartridge — MQTT adapter layer.
//
// Connects to an MQTT broker and subscribes to agent command topics.
// Incoming messages trigger OODA FSM operations via the C FFI, and
// results are published back to corresponding /result topics.
//
// Topic layout (using MQTT single-level wildcards):
//
//   Subscribe:
//     agent/session/new                     — create a new OODA session
//     agent/session/+/advance               — advance session <id> one step
//     agent/session/+/transition            — move session <id> to a state
//     agent/session/+/halt                  — halt session <id>
//     agent/session/+/status                — query session <id> state
//
//   Publish (results):
//     agent/session/new/result              — new session id + initial state
//     agent/session/<id>/advance/result     — transition outcome
//     agent/session/<id>/transition/result  — transition outcome
//     agent/session/<id>/halt/result        — halt confirmation
//     agent/session/<id>/status/result      — current state snapshot
//
// Payloads are JSON-encoded for interoperability with dashboards,
// IoT controllers, and other MQTT consumers.

module agent_mqtt

import json

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
// Payload types — JSON-serialisable structs for MQTT messages.
// ═══════════════════════════════════════════════════════════════════════

// SessionPayload holds a session snapshot published on creation/status.
struct SessionPayload {
	session_id int
	state      string
	loop_count int
}

// TransitionPayload holds the outcome of a state transition.
struct TransitionPayload {
	session_id int
	from       string
	to         string
	success    bool
	next_state string
}

// ErrorPayload carries an error message when an operation fails.
struct ErrorPayload {
	error string
}

// TransitionRequest is the JSON body expected on the transition topic.
struct TransitionRequest {
	state string
}

// ═══════════════════════════════════════════════════════════════════════
// MQTT Client Abstraction
// ═══════════════════════════════════════════════════════════════════════

// MqttPublisher is an interface for publishing messages back to the
// broker.  This allows the core logic to be tested without a real
// MQTT connection.
interface MqttPublisher {
	publish(topic string, payload string) !
}

// ═══════════════════════════════════════════════════════════════════════
// Message Handlers — one per subscribed topic pattern.
// ═══════════════════════════════════════════════════════════════════════

// handle_new_session processes a message on `agent/session/new`.
// Creates a new OODA session and publishes the result.
pub fn handle_new_session(pub_fn MqttPublisher) {
	idx := C.agent_new_session()
	if idx < 0 {
		pub_fn.publish('agent/session/new/result', json.encode(ErrorPayload{
			error: 'no session slots available'
		})) or {}
		return
	}
	pub_fn.publish('agent/session/new/result', json.encode(SessionPayload{
		session_id: idx
		state: 'observe'
		loop_count: 0
	})) or {}
}

// handle_advance processes a message on `agent/session/<id>/advance`.
// Advances the session one OODA step and publishes the result.
pub fn handle_advance(session_id int, pub_fn MqttPublisher) {
	current := C.agent_state(session_id)
	if current < 0 {
		pub_fn.publish('agent/session/${session_id}/advance/result', json.encode(ErrorPayload{
			error: 'session ${session_id} not found'
		})) or {}
		return
	}
	next := C.agent_next_state(current)
	result := C.agent_transition(session_id, next)
	if result < 0 {
		pub_fn.publish('agent/session/${session_id}/advance/result', json.encode(ErrorPayload{
			error: 'advance failed'
		})) or {}
		return
	}
	pub_fn.publish('agent/session/${session_id}/advance/result', json.encode(TransitionPayload{
		session_id: session_id
		from: state_label(current)
		to: state_label(next)
		success: true
		next_state: state_label(C.agent_next_state(next))
	})) or {}
}

// handle_transition processes a message on `agent/session/<id>/transition`.
// The message payload must be a JSON object with a "state" field.
pub fn handle_transition(session_id int, payload string, pub_fn MqttPublisher) {
	result_topic := 'agent/session/${session_id}/transition/result'
	req := json.decode(TransitionRequest, payload) or {
		pub_fn.publish(result_topic, json.encode(ErrorPayload{
			error: 'invalid payload: expected {"state":"<name>"}'
		})) or {}
		return
	}
	target := state_from_name(req.state) or {
		pub_fn.publish(result_topic, json.encode(ErrorPayload{
			error: err.msg()
		})) or {}
		return
	}
	current := C.agent_state(session_id)
	if current < 0 {
		pub_fn.publish(result_topic, json.encode(ErrorPayload{
			error: 'session ${session_id} not found'
		})) or {}
		return
	}
	result := C.agent_transition(session_id, target)
	if result < 0 {
		pub_fn.publish(result_topic, json.encode(ErrorPayload{
			error: 'invalid transition from ${state_label(current)} to ${req.state}'
		})) or {}
		return
	}
	pub_fn.publish(result_topic, json.encode(TransitionPayload{
		session_id: session_id
		from: state_label(current)
		to: req.state
		success: true
		next_state: state_label(C.agent_next_state(target))
	})) or {}
}

// handle_halt processes a message on `agent/session/<id>/halt`.
// Immediately halts the session by transitioning to state 5.
pub fn handle_halt(session_id int, pub_fn MqttPublisher) {
	result_topic := 'agent/session/${session_id}/halt/result'
	current := C.agent_state(session_id)
	if current < 0 {
		pub_fn.publish(result_topic, json.encode(ErrorPayload{
			error: 'session ${session_id} not found'
		})) or {}
		return
	}
	result := C.agent_transition(session_id, 5) // 5 = halted
	if result < 0 {
		pub_fn.publish(result_topic, json.encode(ErrorPayload{
			error: 'halt failed'
		})) or {}
		return
	}
	pub_fn.publish(result_topic, json.encode(SessionPayload{
		session_id: session_id
		state: 'halted'
		loop_count: C.agent_loop_count(session_id)
	})) or {}
}

// handle_status processes a message on `agent/session/<id>/status`.
// Returns the current state and loop count.
pub fn handle_status(session_id int, pub_fn MqttPublisher) {
	result_topic := 'agent/session/${session_id}/status/result'
	s := C.agent_state(session_id)
	if s < 0 {
		pub_fn.publish(result_topic, json.encode(ErrorPayload{
			error: 'session ${session_id} not found'
		})) or {}
		return
	}
	pub_fn.publish(result_topic, json.encode(SessionPayload{
		session_id: session_id
		state: state_label(s)
		loop_count: C.agent_loop_count(session_id)
	})) or {}
}

// ═══════════════════════════════════════════════════════════════════════
// Topic Router — parses incoming MQTT topics and dispatches to handlers.
// ═══════════════════════════════════════════════════════════════════════

// route_message extracts the session id and command from an MQTT topic
// and dispatches to the appropriate handler.
//
// Expected topic formats:
//   agent/session/new
//   agent/session/<id>/advance
//   agent/session/<id>/transition
//   agent/session/<id>/halt
//   agent/session/<id>/status
pub fn route_message(topic string, payload string, pub_fn MqttPublisher) {
	parts := topic.split('/')
	// Minimum valid topic has 3 segments: agent/session/new
	if parts.len < 3 || parts[0] != 'agent' || parts[1] != 'session' {
		return
	}

	// Handle the "new" topic (3 segments, no session id).
	if parts.len == 3 && parts[2] == 'new' {
		handle_new_session(pub_fn)
		return
	}

	// All other topics have 4 segments: agent/session/<id>/<command>
	if parts.len != 4 {
		return
	}
	session_id := parts[2].int()
	command := parts[3]

	match command {
		'advance' { handle_advance(session_id, pub_fn) }
		'transition' { handle_transition(session_id, payload, pub_fn) }
		'halt' { handle_halt(session_id, pub_fn) }
		'status' { handle_status(session_id, pub_fn) }
		else {} // Ignore unknown commands silently.
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// MockPublisher captures published messages for test assertions.
struct MockPublisher {
mut:
	published_topic   string
	published_payload string
}

fn (mut m MockPublisher) publish(topic string, payload string) ! {
	m.published_topic = topic
	m.published_payload = payload
}

// test_route_new_session verifies that a message on agent/session/new
// creates a session and publishes to the result topic.
fn test_route_new_session() {
	mut mock := MockPublisher{}
	route_message('agent/session/new', '', mut mock)
	assert mock.published_topic == 'agent/session/new/result'
	assert mock.published_payload.len > 0
	// Verify the payload decodes to a valid SessionPayload.
	decoded := json.decode(SessionPayload, mock.published_payload) or {
		assert false, 'failed to decode session payload'
		return
	}
	assert decoded.state == 'observe'
	assert decoded.loop_count == 0
}

// test_route_unknown_command verifies that unknown commands are silently
// ignored (no publish, no crash).
fn test_route_unknown_command() {
	mut mock := MockPublisher{}
	route_message('agent/session/0/reboot', '', mut mock)
	// Nothing should have been published.
	assert mock.published_topic == ''
}
