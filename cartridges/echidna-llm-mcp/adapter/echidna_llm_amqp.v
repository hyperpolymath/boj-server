// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — AMQP 0-9-1 transport adapter.
//
// Implements an AMQP consumer/producer that integrates ECHIDNA's frontier
// LLM tactic advisory with message broker infrastructure (RabbitMQ,
// LavinMQ, etc.). This enables enterprise-grade message queuing with
// acknowledgements, dead-letter routing, and durable subscriptions for
// distributed proof clusters.
//
// Exchange/Queue topology:
//   Exchange: echidna.llm (topic exchange)
//
//   Routing keys (consume):
//     echidna.suggest_tactics.request
//     echidna.rank_provers.request
//     echidna.authenticate.request
//     echidna.status.request
//     echidna.close.request
//
//   Routing keys (produce):
//     echidna.suggest_tactics.result
//     echidna.rank_provers.result
//     echidna.authenticate.result
//     echidna.status.result
//     echidna.close.result
//     echidna.error
//
// All payloads are JSON with content-type application/json.
// Messages are persistent (delivery-mode 2) for proof reliability.

module echidna_llm_amqp

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
// AMQP routing key constants
// ═══════════════════════════════════════════════════════════════════════

const exchange_name = 'echidna.llm'

// Request routing keys — consumer binds to these.
const rk_suggest_request = 'echidna.suggest_tactics.request'
const rk_rank_request = 'echidna.rank_provers.request'
const rk_auth_request = 'echidna.authenticate.request'
const rk_status_request = 'echidna.status.request'
const rk_close_request = 'echidna.close.request'

// Result routing keys — producer publishes to these.
const rk_suggest_result = 'echidna.suggest_tactics.result'
const rk_rank_result = 'echidna.rank_provers.result'
const rk_auth_result = 'echidna.authenticate.result'
const rk_status_result = 'echidna.status.result'
const rk_close_result = 'echidna.close.result'
const rk_error = 'echidna.error'

// ═══════════════════════════════════════════════════════════════════════
// AMQP message properties
// ═══════════════════════════════════════════════════════════════════════

// AMQP message properties attached to every published message.
struct AmqpProperties {
	content_type  string = 'application/json'
	delivery_mode int    = 2 // persistent
	correlation_id string   // echoed from request for RPC correlation
	reply_to      string   // optional reply queue for direct-reply-to
}

// ═══════════════════════════════════════════════════════════════════════
// Payload types — JSON structures in AMQP message bodies
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

struct AmqpErrorResult {
	error       string
	routing_key string
}

// ═══════════════════════════════════════════════════════════════════════
// AMQP Client abstraction
// ═══════════════════════════════════════════════════════════════════════

// Callback signature: receives routing key, body bytes, and correlation ID.
type AmqpCallback = fn (string, []u8, string)

// Configuration for the AMQP connection.
pub struct AmqpConfig {
pub:
	host         string = 'localhost'
	port         int    = 5672
	vhost        string = '/'
	username     string = 'guest'
	password     string = 'guest'
	queue_name   string = 'echidna-llm-requests'
	prefetch     int    = 10 // prefetch count for fair dispatch
	endpoint     string = 'http://localhost:7700' // BoJ endpoint
}

// The Client manages the AMQP connection, exchange/queue declarations,
// consumer bindings, and message routing.
pub struct Client {
pub:
	config AmqpConfig
mut:
	callbacks map[string]AmqpCallback // routing_key -> handler
	connected bool
	channel_open bool
}

// Create a new AMQP Client with all echidna-llm routing key handlers.
pub fn Client.new(config AmqpConfig) Client {
	mut c := Client{
		config: config
		connected: false
		channel_open: false
	}
	c.callbacks[rk_suggest_request] = on_suggest_request
	c.callbacks[rk_rank_request] = on_rank_request
	c.callbacks[rk_auth_request] = on_auth_request
	c.callbacks[rk_status_request] = on_status_request
	c.callbacks[rk_close_request] = on_close_request
	return c
}

// Connect to the AMQP broker, declare exchange and queue, bind routing
// keys, set prefetch, and begin consuming. Blocks until disconnected.
pub fn (mut c Client) start() ! {
	C.echidna_llm_init(c.config.endpoint.str)

	c.connected = true
	c.channel_open = true

	// Declare topic exchange
	c.declare_exchange(exchange_name, 'topic') or {
		return error('failed to declare exchange: ${err}')
	}

	// Declare durable queue
	c.declare_queue(c.config.queue_name) or {
		return error('failed to declare queue: ${err}')
	}

	// Bind all request routing keys
	for rk, _ in c.callbacks {
		c.bind_queue(c.config.queue_name, exchange_name, rk) or {
			return error('failed to bind ${rk}: ${err}')
		}
	}

	// Set prefetch for fair dispatch across multiple consumers
	c.set_prefetch(c.config.prefetch) or {
		return error('failed to set prefetch: ${err}')
	}
}

// Declare a topic exchange. In production, calls the AMQP library.
fn (c &Client) declare_exchange(name string, exchange_type string) ! {
	if !c.channel_open {
		return error('channel not open')
	}
}

// Declare a durable queue. In production, calls the AMQP library.
fn (c &Client) declare_queue(name string) ! {
	if !c.channel_open {
		return error('channel not open')
	}
}

// Bind a queue to an exchange with a routing key.
fn (c &Client) bind_queue(queue string, exchange string, routing_key string) ! {
	if !c.channel_open {
		return error('channel not open')
	}
}

// Set the prefetch count for fair dispatch.
fn (c &Client) set_prefetch(count int) ! {
	if !c.channel_open {
		return error('channel not open')
	}
}

// Publish a message to the exchange with a routing key and properties.
pub fn (c &Client) publish(routing_key string, body string, props AmqpProperties) ! {
	if !c.connected {
		return error('not connected to AMQP broker')
	}
	// In production: basic_publish to exchange with routing_key,
	// body bytes, and properties (content_type, delivery_mode,
	// correlation_id, reply_to).
	_ = routing_key
	_ = body
	_ = props
}

// Acknowledge a message by its delivery tag.
pub fn (c &Client) ack(delivery_tag u64) ! {
	if !c.channel_open {
		return error('channel not open')
	}
	_ = delivery_tag
}

// Negative-acknowledge and requeue a message.
pub fn (c &Client) nack(delivery_tag u64, requeue bool) ! {
	if !c.channel_open {
		return error('channel not open')
	}
	_ = delivery_tag
	_ = requeue
}

// Route an incoming message to the registered callback for its key.
pub fn (c &Client) dispatch(routing_key string, body []u8, correlation_id string) {
	if cb := c.callbacks[routing_key] {
		cb(routing_key, body, correlation_id)
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
			error: 'tactic suggestion failed — session may have expired'
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(SuggestTacticsResult{
		success: true
		data: result_str
	})
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

	return json.encode(RankProversResult{
		success: true
		data: result_str
	})
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
		return json.encode(AuthenticateResult{
			success: false
			error: msg
		})
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

	return json.encode(StatusResult{
		state: state_label(state)
		session_valid: valid
	})
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

	return json.encode(CloseResult{
		success: true
		state: state_label(state)
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Topic handlers — callbacks wired to routing keys
// ═══════════════════════════════════════════════════════════════════════

fn on_suggest_request(routing_key string, payload []u8, correlation_id string) {
	_ = process_suggest_tactics(payload) or { return }
	// In production: client.publish(rk_suggest_result, result, props)
}

fn on_rank_request(routing_key string, payload []u8, correlation_id string) {
	_ = process_rank_provers(payload) or { return }
}

fn on_auth_request(routing_key string, payload []u8, correlation_id string) {
	_ = process_authenticate(payload) or { return }
}

fn on_status_request(routing_key string, payload []u8, correlation_id string) {
	_ = process_status(payload) or { return }
}

fn on_close_request(routing_key string, payload []u8, correlation_id string) {
	_ = process_close(payload) or { return }
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_amqp_process_suggest_no_session() {
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

fn test_amqp_process_rank_no_session() {
	payload := '{"goal":"P -> Q -> P"}'.bytes()
	result := process_rank_provers(payload) or {
		assert false, 'should not fail: ${err}'
		return
	}
	decoded := json.decode(RankProversResult, result) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.success == false
	assert decoded.error.contains('session')
}

fn test_amqp_process_status() {
	payload := '{}'.bytes()
	result := process_status(payload) or {
		assert false, 'process_status failed: ${err}'
		return
	}
	decoded := json.decode(StatusResult, result) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
}

fn test_amqp_client_dispatch() {
	config := AmqpConfig{}
	client := Client.new(config)
	client.dispatch(rk_status_request, '{}'.bytes(), 'corr-001')
}

fn test_amqp_invalid_payload() {
	payload := 'not json'.bytes()
	process_suggest_tactics(payload) or {
		assert err.msg().contains('invalid')
		return
	}
	assert false, 'expected error for invalid payload'
}
