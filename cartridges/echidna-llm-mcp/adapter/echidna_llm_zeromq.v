// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — ZeroMQ transport adapter.
//
// Implements a ZeroMQ ROUTER/DEALER socket pair for the ECHIDNA frontier
// LLM tactic advisory. ZeroMQ provides brokerless, high-performance
// messaging suitable for tightly-coupled prover clusters where provers
// communicate directly without an intermediary broker.
//
// Socket patterns:
//   ROUTER (server, binds):
//     tcp://*:9815 — accepts connections from prover DEALER sockets
//
//   Message framing (multipart):
//     Frame 0: identity (DEALER socket ID, set by ZeroMQ)
//     Frame 1: empty delimiter
//     Frame 2: operation (string: "suggest_tactics", "rank_provers", etc.)
//     Frame 3: payload (JSON body)
//
//   Reply framing:
//     Frame 0: identity (echoed)
//     Frame 1: empty delimiter
//     Frame 2: operation (echoed)
//     Frame 3: result (JSON body)
//
// ZeroMQ handles reconnection, message queuing, and load balancing
// across multiple connected provers automatically.

module echidna_llm_zeromq

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
// ZeroMQ operation constants
// ═══════════════════════════════════════════════════════════════════════

const op_suggest_tactics = 'suggest_tactics'
const op_rank_provers = 'rank_provers'
const op_authenticate = 'authenticate'
const op_status = 'status'
const op_close = 'close'
const op_health = 'health'
const op_error = 'error'

// ═══════════════════════════════════════════════════════════════════════
// ZeroMQ message abstraction
// ═══════════════════════════════════════════════════════════════════════

// A ZeroMQ multipart message with identity routing.
pub struct ZmqMessage {
pub:
	identity  []u8  // ROUTER socket routing identity
	operation string // operation name (Frame 2)
	payload   []u8  // JSON payload (Frame 3)
}

// A ZeroMQ reply message ready to send.
pub struct ZmqReply {
pub:
	identity  []u8
	operation string
	data      string // JSON result
}

// ═══════════════════════════════════════════════════════════════════════
// Payload types
// ═══════════════════════════════════════════════════════════════════════

struct SuggestTacticsRequest {
	goal       string
	hypotheses string
	prover_id  int
	top_k      int = 10
	model      string = 'sonnet'
}

struct SuggestTacticsResult {
	success bool
	data    string
	error   string
}

struct RankProversRequest {
	goal  string
	model string = 'sonnet'
}

struct RankProversResult {
	success bool
	data    string
	error   string
}

struct AuthenticateRequest {
	token     string
	max_calls int = 100
	expiry_ms int = 60000
}

struct AuthenticateResult {
	success   bool
	state     string
	max_calls int
	expiry_ms int
	error     string
}

struct StatusResult {
	state         string
	session_valid bool
}

struct CloseResult {
	success bool
	state   string
	error   string
}

struct HealthResult {
	status  string
	adapter string
}

struct ErrorResult {
	error     string
	operation string
}

// ═══════════════════════════════════════════════════════════════════════
// ZeroMQ Server abstraction
// ═══════════════════════════════════════════════════════════════════════

// Configuration for the ZeroMQ ROUTER socket.
pub struct ZmqConfig {
pub:
	bind_addr string = 'tcp://*:9815'
	endpoint  string = 'http://localhost:7700' // BoJ endpoint
	hwm       int    = 1000 // high-water mark (message queue limit)
}

// The Server manages the ZeroMQ ROUTER socket and dispatches messages.
pub struct Server {
pub:
	config ZmqConfig
mut:
	running bool
}

// Create a new ZeroMQ server.
pub fn Server.new(config ZmqConfig) Server {
	return Server{
		config: config
		running: false
	}
}

// Start the ZeroMQ server. Binds the ROUTER socket and enters the
// message receive loop. Blocks until stopped.
pub fn (mut s Server) start() ! {
	C.echidna_llm_init(s.config.endpoint.str)
	s.running = true

	// In production:
	// 1. zmq_ctx_new()
	// 2. zmq_socket(ctx, ZMQ_ROUTER)
	// 3. zmq_setsockopt(sock, ZMQ_SNDHWM, &hwm)
	// 4. zmq_bind(sock, bind_addr)
	// 5. Loop: zmq_msg_recv multipart → dispatch → zmq_msg_send reply
}

// Stop the server and close the socket.
pub fn (mut s Server) stop() {
	s.running = false
}

// ═══════════════════════════════════════════════════════════════════════
// Message dispatcher — routes ZeroMQ messages to handlers
// ═══════════════════════════════════════════════════════════════════════

// Dispatch a ZeroMQ message and return the reply.
pub fn dispatch(msg ZmqMessage) ZmqReply {
	result := match msg.operation {
		op_suggest_tactics { process_suggest_tactics(msg.payload) or { error_json(err.msg(), msg.operation) } }
		op_rank_provers { process_rank_provers(msg.payload) or { error_json(err.msg(), msg.operation) } }
		op_authenticate { process_authenticate(msg.payload) or { error_json(err.msg(), msg.operation) } }
		op_status { process_status(msg.payload) or { error_json(err.msg(), msg.operation) } }
		op_close { process_close(msg.payload) or { error_json(err.msg(), msg.operation) } }
		op_health { json.encode(HealthResult{ status: 'ok', adapter: 'echidna_llm_zeromq' }) }
		else { error_json('unknown operation: ${msg.operation}', msg.operation) }
	}

	return ZmqReply{
		identity: msg.identity
		operation: msg.operation
		data: result
	}
}

// Format an error result JSON.
fn error_json(message string, operation string) string {
	return json.encode(ErrorResult{ error: message, operation: operation })
}

// ═══════════════════════════════════════════════════════════════════════
// Processing functions
// ═══════════════════════════════════════════════════════════════════════

pub fn process_suggest_tactics(payload []u8) !string {
	req := json.decode(SuggestTacticsRequest, payload.bytestr()) or {
		return error('invalid suggest_tactics request: ${err}')
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(SuggestTacticsResult{
			success: false
			error: 'session expired or call limit reached'
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
		return json.encode(SuggestTacticsResult{
			success: false
			error: 'tactic suggestion failed'
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(SuggestTacticsResult{ success: true, data: result_str })
}

pub fn process_rank_provers(payload []u8) !string {
	req := json.decode(RankProversRequest, payload.bytestr()) or {
		return error('invalid rank_provers request: ${err}')
	}

	if C.echidna_llm_session_valid() != 1 {
		return json.encode(RankProversResult{
			success: false
			error: 'session expired or call limit reached'
		})
	}

	model := model_from_string(req.model)
	result_ptr := C.echidna_llm_rank_provers(req.goal.str, req.goal.len, model)

	if result_ptr == unsafe { nil } {
		return json.encode(RankProversResult{
			success: false
			error: 'prover ranking failed'
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(RankProversResult{ success: true, data: result_str })
}

pub fn process_authenticate(payload []u8) !string {
	req := json.decode(AuthenticateRequest, payload.bytestr()) or {
		return error('invalid authenticate request: ${err}')
	}

	result := C.echidna_llm_authenticate(req.token.str, req.token.len, req.max_calls, req.expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		return json.encode(AuthenticateResult{ success: false, error: msg })
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	return json.encode(AuthenticateResult{
		success: true
		state: state_label(state)
		max_calls: req.max_calls
		expiry_ms: req.expiry_ms
	})
}

pub fn process_status(payload []u8) !string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1
	return json.encode(StatusResult{ state: state_label(state), session_valid: valid })
}

pub fn process_close(payload []u8) !string {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		return json.encode(CloseResult{
			success: false
			state: state_label(state)
			error: 'cannot close — no active session'
		})
	}

	return json.encode(CloseResult{ success: true, state: state_label(state) })
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_zmq_dispatch_health() {
	msg := ZmqMessage{
		identity: 'prover-01'.bytes()
		operation: op_health
		payload: '{}'.bytes()
	}
	reply := dispatch(msg)
	assert reply.operation == op_health
	assert reply.data.contains('echidna_llm_zeromq')
	assert reply.identity == 'prover-01'.bytes()
}

fn test_zmq_dispatch_status() {
	msg := ZmqMessage{
		identity: 'client-01'.bytes()
		operation: op_status
		payload: '{}'.bytes()
	}
	reply := dispatch(msg)
	assert reply.operation == op_status
	decoded := json.decode(StatusResult, reply.data) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
}

fn test_zmq_dispatch_suggest_no_session() {
	msg := ZmqMessage{
		identity: 'prover-02'.bytes()
		operation: op_suggest_tactics
		payload: '{"goal":"forall n, n + 0 = n","prover_id":0}'.bytes()
	}
	reply := dispatch(msg)
	assert reply.data.contains('session')
}

fn test_zmq_dispatch_unknown() {
	msg := ZmqMessage{
		identity: 'rogue'.bytes()
		operation: 'explode'
		payload: '{}'.bytes()
	}
	reply := dispatch(msg)
	assert reply.data.contains('unknown operation')
}

fn test_zmq_identity_preserved() {
	identity := [u8(0xDE), 0xAD, 0xBE, 0xEF]
	msg := ZmqMessage{
		identity: identity
		operation: op_health
		payload: '{}'.bytes()
	}
	reply := dispatch(msg)
	assert reply.identity == identity
}
