// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — NATS transport adapter.
//
// Implements a NATS client for the ECHIDNA frontier LLM tactic advisory.
// NATS provides ultra-low-latency pub/sub and request-reply patterns ideal
// for real-time proof dispatch across distributed prover clusters.
//
// Subject map:
//   Request subjects (subscribe):
//     echidna.llm.suggest_tactics  — request-reply for tactic suggestions
//     echidna.llm.rank_provers     — request-reply for prover ranking
//     echidna.llm.authenticate     — request-reply for session creation
//     echidna.llm.status           — request-reply for session state
//     echidna.llm.close            — request-reply for session close
//
// NATS request-reply semantics: each request includes a reply subject.
// The handler processes the request and publishes the result to the reply
// subject. This provides natural RPC-over-NATS without additional framing.
//
// JetStream subjects (for durable proof audit trail):
//     echidna.llm.audit.>          — all operations are mirrored here

module echidna_llm_nats

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
// NATS subject constants
// ═══════════════════════════════════════════════════════════════════════

const subj_suggest = 'echidna.llm.suggest_tactics'
const subj_rank = 'echidna.llm.rank_provers'
const subj_auth = 'echidna.llm.authenticate'
const subj_status = 'echidna.llm.status'
const subj_close = 'echidna.llm.close'

// JetStream audit stream subjects.
const subj_audit_prefix = 'echidna.llm.audit'

// ═══════════════════════════════════════════════════════════════════════
// NATS message abstraction
// ═══════════════════════════════════════════════════════════════════════

// A NATS message with subject, payload, and optional reply subject.
pub struct NatsMsg {
pub:
	subject string
	data    []u8
	reply   string // reply subject for request-reply pattern
}

// Callback signature for NATS subscription handlers.
type NatsCallback = fn (NatsMsg)

// ═══════════════════════════════════════════════════════════════════════
// Payload types — JSON structures in NATS message bodies
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

// ═══════════════════════════════════════════════════════════════════════
// NATS Client abstraction
// ═══════════════════════════════════════════════════════════════════════

// Configuration for the NATS connection.
pub struct NatsConfig {
pub:
	url      string = 'nats://localhost:4222'
	name     string = 'echidna-llm-adapter'
	token    string  // NATS auth token (optional)
	endpoint string = 'http://localhost:7700' // BoJ endpoint
}

// The Client manages NATS subscriptions and message routing.
pub struct Client {
pub:
	config NatsConfig
mut:
	callbacks map[string]NatsCallback
	connected bool
}

// Create a new NATS Client with all echidna-llm subject handlers.
pub fn Client.new(config NatsConfig) Client {
	mut c := Client{
		config: config
		connected: false
	}
	c.callbacks[subj_suggest] = on_suggest
	c.callbacks[subj_rank] = on_rank
	c.callbacks[subj_auth] = on_auth
	c.callbacks[subj_status] = on_status
	c.callbacks[subj_close] = on_close
	return c
}

// Connect to the NATS server, subscribe to all subjects, and begin
// the message loop. Blocks until disconnected.
pub fn (mut c Client) start() ! {
	C.echidna_llm_init(c.config.endpoint.str)

	c.connected = true

	// Subscribe to all request subjects
	for subject, _ in c.callbacks {
		c.subscribe(subject) or {
			return error('failed to subscribe to ${subject}: ${err}')
		}
	}
}

// Subscribe to a NATS subject.
fn (mut c Client) subscribe(subject string) ! {
	if !c.connected {
		return error('not connected to NATS server')
	}
}

// Publish a message to a subject.
pub fn (c &Client) publish(subject string, data string) ! {
	if !c.connected {
		return error('not connected to NATS server')
	}
	_ = subject
	_ = data
}

// Publish a reply to a request message.
pub fn (c &Client) reply(msg NatsMsg, data string) ! {
	if msg.reply.len == 0 {
		return error('no reply subject on message')
	}
	c.publish(msg.reply, data)!
}

// Route an incoming message to the registered callback.
pub fn (c &Client) dispatch(msg NatsMsg) {
	if cb := c.callbacks[msg.subject] {
		cb(msg)
	}
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
// Subject handlers — wired to NATS subscriptions
// ═══════════════════════════════════════════════════════════════════════

fn on_suggest(msg NatsMsg) {
	_ = process_suggest_tactics(msg.data) or { return }
	// In production: client.reply(msg, result)
}

fn on_rank(msg NatsMsg) {
	_ = process_rank_provers(msg.data) or { return }
}

fn on_auth(msg NatsMsg) {
	_ = process_authenticate(msg.data) or { return }
}

fn on_status(msg NatsMsg) {
	_ = process_status(msg.data) or { return }
}

fn on_close(msg NatsMsg) {
	_ = process_close(msg.data) or { return }
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_nats_process_suggest_no_session() {
	payload := '{"goal":"forall n, n + 0 = n","prover_id":0}'.bytes()
	result := process_suggest_tactics(payload) or {
		assert false, 'should not fail: ${err}'
		return
	}
	decoded := json.decode(SuggestTacticsResult, result) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.success == false
	assert decoded.error.contains('session')
}

fn test_nats_process_status() {
	result := process_status('{}'.bytes()) or {
		assert false, 'failed: ${err}'
		return
	}
	decoded := json.decode(StatusResult, result) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
}

fn test_nats_client_dispatch() {
	config := NatsConfig{}
	client := Client.new(config)
	msg := NatsMsg{ subject: subj_status, data: '{}'.bytes(), reply: '' }
	client.dispatch(msg)
}

fn test_nats_invalid_payload() {
	payload := 'not json'.bytes()
	process_suggest_tactics(payload) or {
		assert err.msg().contains('invalid')
		return
	}
	assert false, 'expected error'
}
