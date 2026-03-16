// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Agent-MCP Cartridge — Cap'n Proto adapter layer.
//
// Provides Cap'n Proto serialisation and RPC dispatch for the OODA loop
// FSM.  Messages are encoded as compact binary frames using a
// length-prefixed struct layout.  Each struct type has a fixed schema
// with known field offsets, following Cap'n Proto conventions.
//
// Struct definitions:
//   Session              — session_id:u32, state:u8, loop_count:u32
//   TransitionRequest    — session_id:u32, target_state:u8
//   TransitionResponse   — session_id:u32, from:u8, to:u8, success:u8, next_state:u8
//   ValidationResult     — from:u8, to:u8, allowed:u8
//   ToolCallInfo         — kind:u8, has_side_effects:u8, requires_safety:u8
//   SafetyCheckInfo      — outcome:u8, allows_execution:u8, needs_human:u8
//
// RPC method IDs:
//   1 = newSession       — no input, returns Session
//   2 = transition       — input TransitionRequest, returns TransitionResponse
//   3 = advance          — input session_id:u32, returns TransitionResponse
//   4 = halt             — input session_id:u32, returns Session
//   5 = status           — input session_id:u32, returns Session
//   6 = validate         — input from:u8 + to:u8, returns ValidationResult
//
// Wire format (little-endian):
//   [method_id:u8][payload_len:u16][payload bytes...]

module agent_capnproto

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
// RPC Method IDs — constants for the wire protocol.
// ═══════════════════════════════════════════════════════════════════════

const method_new_session = u8(1)
const method_transition  = u8(2)
const method_advance     = u8(3)
const method_halt        = u8(4)
const method_status      = u8(5)
const method_validate    = u8(6)

// ═══════════════════════════════════════════════════════════════════════
// Struct Definitions — binary-serialisable data types.
// Each struct can encode itself to a byte array and decode from one.
// Layout is little-endian with fixed offsets.
// ═══════════════════════════════════════════════════════════════════════

// Session represents a session snapshot.
// Wire layout: [session_id:4][state:1][loop_count:4] = 9 bytes
struct Session {
	session_id int
	state      u8
	loop_count int
}

// encode serialises a Session to a 9-byte little-endian buffer.
fn (s Session) encode() []u8 {
	mut buf := []u8{len: 9}
	// session_id at offset 0 (4 bytes LE)
	buf[0] = u8(s.session_id & 0xFF)
	buf[1] = u8((s.session_id >> 8) & 0xFF)
	buf[2] = u8((s.session_id >> 16) & 0xFF)
	buf[3] = u8((s.session_id >> 24) & 0xFF)
	// state at offset 4 (1 byte)
	buf[4] = s.state
	// loop_count at offset 5 (4 bytes LE)
	buf[5] = u8(s.loop_count & 0xFF)
	buf[6] = u8((s.loop_count >> 8) & 0xFF)
	buf[7] = u8((s.loop_count >> 16) & 0xFF)
	buf[8] = u8((s.loop_count >> 24) & 0xFF)
	return buf
}

// decode_session reads a Session from a 9-byte little-endian buffer.
fn decode_session(buf []u8) !Session {
	if buf.len < 9 {
		return error('buffer too short for Session (need 9, got ${buf.len})')
	}
	return Session{
		session_id: int(buf[0]) | (int(buf[1]) << 8) | (int(buf[2]) << 16) | (int(buf[3]) << 24)
		state: buf[4]
		loop_count: int(buf[5]) | (int(buf[6]) << 8) | (int(buf[7]) << 16) | (int(buf[8]) << 24)
	}
}

// TransitionRequest carries the target state for a transition.
// Wire layout: [session_id:4][target_state:1] = 5 bytes
struct TransitionRequest {
	session_id   int
	target_state u8
}

// decode_transition_request reads a TransitionRequest from a 5-byte buffer.
fn decode_transition_request(buf []u8) !TransitionRequest {
	if buf.len < 5 {
		return error('buffer too short for TransitionRequest (need 5, got ${buf.len})')
	}
	return TransitionRequest{
		session_id: int(buf[0]) | (int(buf[1]) << 8) | (int(buf[2]) << 16) | (int(buf[3]) << 24)
		target_state: buf[4]
	}
}

// TransitionResponse carries the full result of a state transition.
// Wire layout: [session_id:4][from:1][to:1][success:1][next_state:1] = 8 bytes
struct TransitionResponse {
	session_id int
	from       u8
	to         u8
	success    u8
	next_state u8
}

// encode serialises a TransitionResponse to an 8-byte little-endian buffer.
fn (t TransitionResponse) encode() []u8 {
	mut buf := []u8{len: 8}
	buf[0] = u8(t.session_id & 0xFF)
	buf[1] = u8((t.session_id >> 8) & 0xFF)
	buf[2] = u8((t.session_id >> 16) & 0xFF)
	buf[3] = u8((t.session_id >> 24) & 0xFF)
	buf[4] = t.from
	buf[5] = t.to
	buf[6] = t.success
	buf[7] = t.next_state
	return buf
}

// ValidationResult carries the legality check for a proposed transition.
// Wire layout: [from:1][to:1][allowed:1] = 3 bytes
struct ValidationResult {
	from    u8
	to      u8
	allowed u8
}

// encode serialises a ValidationResult to a 3-byte buffer.
fn (v ValidationResult) encode() []u8 {
	return [v.from, v.to, v.allowed]
}

// ToolCallInfo carries tool-call safety metadata.
// Wire layout: [kind:1][has_side_effects:1][requires_safety:1] = 3 bytes
struct ToolCallInfo {
	kind                  u8
	has_side_effects      u8
	requires_safety_check u8
}

// encode serialises a ToolCallInfo to a 3-byte buffer.
fn (t ToolCallInfo) encode() []u8 {
	return [t.kind, t.has_side_effects, t.requires_safety_check]
}

// SafetyCheckInfo carries safety-check metadata.
// Wire layout: [outcome:1][allows_execution:1][needs_human:1] = 3 bytes
struct SafetyCheckInfo {
	outcome          u8
	allows_execution u8
	needs_human      u8
}

// encode serialises a SafetyCheckInfo to a 3-byte buffer.
fn (s SafetyCheckInfo) encode() []u8 {
	return [s.outcome, s.allows_execution, s.needs_human]
}

// ═══════════════════════════════════════════════════════════════════════
// Frame encoding/decoding — wire protocol with method id + length prefix.
// ═══════════════════════════════════════════════════════════════════════

// encode_frame wraps a method ID and payload in the wire format:
//   [method_id:1][payload_len:2 LE][payload bytes...]
fn encode_frame(method_id u8, payload []u8) []u8 {
	len_lo := u8(payload.len & 0xFF)
	len_hi := u8((payload.len >> 8) & 0xFF)
	mut frame := [method_id, len_lo, len_hi]
	frame << payload
	return frame
}

// decode_frame extracts the method ID, payload length, and payload
// from a wire-format frame.
fn decode_frame(buf []u8) !(u8, []u8) {
	if buf.len < 3 {
		return error('frame too short (need at least 3 bytes)')
	}
	mid := buf[0]
	plen := int(buf[1]) | (int(buf[2]) << 8)
	if buf.len < 3 + plen {
		return error('frame payload truncated (declared ${plen}, have ${buf.len - 3})')
	}
	return mid, buf[3..3 + plen]
}

// ═══════════════════════════════════════════════════════════════════════
// RPC Dispatch — route a decoded frame to the correct handler.
// ═══════════════════════════════════════════════════════════════════════

// dispatch_rpc takes a raw wire-format frame, decodes it, calls the
// appropriate FFI functions, and returns the encoded response frame.
pub fn dispatch_rpc(frame []u8) ![]u8 {
	method_id, payload := decode_frame(frame)!

	return match method_id {
		method_new_session { rpc_new_session() }
		method_transition { rpc_transition(payload) }
		method_advance { rpc_advance(payload) }
		method_halt { rpc_halt(payload) }
		method_status { rpc_status(payload) }
		method_validate { rpc_validate(payload) }
		else { error('unknown RPC method id: ${method_id}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// RPC Handlers — one function per method ID.
// ═══════════════════════════════════════════════════════════════════════

// rpc_new_session creates a new OODA session.  No input payload.
// Returns a Session frame.
fn rpc_new_session() ![]u8 {
	idx := C.agent_new_session()
	if idx < 0 {
		return error('no session slots available')
	}
	sess := Session{
		session_id: idx
		state: 1 // observe
		loop_count: 0
	}
	return encode_frame(method_new_session, sess.encode())
}

// rpc_transition moves a session to the target state.
// Input: TransitionRequest (5 bytes).  Returns TransitionResponse frame.
fn rpc_transition(payload []u8) ![]u8 {
	req := decode_transition_request(payload)!
	current := C.agent_state(req.session_id)
	if current < 0 {
		return error('session ${req.session_id} not found')
	}
	result := C.agent_transition(req.session_id, int(req.target_state))
	success := u8(if result >= 0 { 1 } else { 0 })
	next := u8(C.agent_next_state(int(req.target_state)))
	resp := TransitionResponse{
		session_id: req.session_id
		from: u8(current)
		to: req.target_state
		success: success
		next_state: next
	}
	return encode_frame(method_transition, resp.encode())
}

// rpc_advance moves a session to the next OODA step.
// Input: session_id as 4-byte LE u32.  Returns TransitionResponse frame.
fn rpc_advance(payload []u8) ![]u8 {
	if payload.len < 4 {
		return error('advance requires 4-byte session_id')
	}
	session_id := int(payload[0]) | (int(payload[1]) << 8) | (int(payload[2]) << 16) | (int(payload[3]) << 24)
	current := C.agent_state(session_id)
	if current < 0 {
		return error('session ${session_id} not found')
	}
	next := C.agent_next_state(current)
	result := C.agent_transition(session_id, next)
	success := u8(if result >= 0 { 1 } else { 0 })
	after_next := u8(C.agent_next_state(next))
	resp := TransitionResponse{
		session_id: session_id
		from: u8(current)
		to: u8(next)
		success: success
		next_state: after_next
	}
	return encode_frame(method_advance, resp.encode())
}

// rpc_halt halts a session immediately.
// Input: session_id as 4-byte LE u32.  Returns Session frame.
fn rpc_halt(payload []u8) ![]u8 {
	if payload.len < 4 {
		return error('halt requires 4-byte session_id')
	}
	session_id := int(payload[0]) | (int(payload[1]) << 8) | (int(payload[2]) << 16) | (int(payload[3]) << 24)
	current := C.agent_state(session_id)
	if current < 0 {
		return error('session ${session_id} not found')
	}
	C.agent_transition(session_id, 5) // 5 = halted
	sess := Session{
		session_id: session_id
		state: 5
		loop_count: C.agent_loop_count(session_id)
	}
	return encode_frame(method_halt, sess.encode())
}

// rpc_status returns the current state of a session.
// Input: session_id as 4-byte LE u32.  Returns Session frame.
fn rpc_status(payload []u8) ![]u8 {
	if payload.len < 4 {
		return error('status requires 4-byte session_id')
	}
	session_id := int(payload[0]) | (int(payload[1]) << 8) | (int(payload[2]) << 16) | (int(payload[3]) << 24)
	s := C.agent_state(session_id)
	if s < 0 {
		return error('session ${session_id} not found')
	}
	sess := Session{
		session_id: session_id
		state: u8(s)
		loop_count: C.agent_loop_count(session_id)
	}
	return encode_frame(method_status, sess.encode())
}

// rpc_validate checks whether a state transition is legal.
// Input: [from:1][to:1] = 2 bytes.  Returns ValidationResult frame.
fn rpc_validate(payload []u8) ![]u8 {
	if payload.len < 2 {
		return error('validate requires 2 bytes (from, to)')
	}
	from := payload[0]
	to := payload[1]
	allowed := u8(if C.agent_validate_ooda(int(from), int(to)) == 1 { 1 } else { 0 })
	result := ValidationResult{
		from: from
		to: to
		allowed: allowed
	}
	return encode_frame(method_validate, result.encode())
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// test_session_encode_decode verifies that Session round-trips through
// encode/decode without data loss.
fn test_session_encode_decode() {
	original := Session{
		session_id: 42
		state: 3
		loop_count: 7
	}
	buf := original.encode()
	assert buf.len == 9
	decoded := decode_session(buf) or {
		assert false, 'decode failed'
		return
	}
	assert decoded.session_id == 42
	assert decoded.state == 3
	assert decoded.loop_count == 7
}

// test_frame_encode_decode verifies that the wire-format frame
// round-trips correctly.
fn test_frame_encode_decode() {
	payload := [u8(0x01), 0x02, 0x03]
	frame := encode_frame(method_new_session, payload)
	// Frame = [method:1][len_lo:1][len_hi:1][payload:3] = 6 bytes
	assert frame.len == 6
	assert frame[0] == method_new_session
	mid, decoded_payload := decode_frame(frame) or {
		assert false, 'decode failed'
		return
	}
	assert mid == method_new_session
	assert decoded_payload == payload
}

// test_validation_result_encode verifies that ValidationResult produces
// a 3-byte buffer with correct field ordering.
fn test_validation_result_encode() {
	vr := ValidationResult{
		from: 1
		to: 2
		allowed: 1
	}
	buf := vr.encode()
	assert buf.len == 3
	assert buf[0] == 1 // from = observe
	assert buf[1] == 2 // to = orient
	assert buf[2] == 1 // allowed = true
}
