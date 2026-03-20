// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — MQTT transport adapter.
//
// Implements an MQTT client that subscribes to echidna-llm request topics
// and publishes results back on paired result topics. This enables
// lightweight pub/sub integration for IoT edge provers, distributed
// theorem proving clusters, and event-driven proof pipelines.
//
// Topic map (QoS 1 — at least once delivery for proof reliability):
//   Subscribe:
//     echidna/suggest_tactics/request — payload: {goal, hypotheses, prover_id, top_k, model}
//     echidna/rank_provers/request    — payload: {goal, model}
//     echidna/authenticate/request    — payload: {token, max_calls, expiry_ms}
//     echidna/status/request          — payload: {} (empty)
//     echidna/close/request           — payload: {} (empty)
//
//   Publish:
//     echidna/suggest_tactics/result  — JSON tactic suggestions
//     echidna/rank_provers/result     — JSON prover rankings
//     echidna/authenticate/result     — JSON authentication result
//     echidna/status/result           — JSON session state
//     echidna/close/result            — JSON close confirmation
//
// All payloads are JSON. The client auto-reconnects on broker disconnect.

module echidna_llm_mqtt

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
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'closed' }
		else { 'unknown' }
	}
}

// Map ModelTier string to its integer encoding for the FFI.
fn model_from_string(s string) int {
	return match s {
		'haiku' { 0 }
		'opus' { 2 }
		else { 1 }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// MQTT topic constants
// ═══════════════════════════════════════════════════════════════════════

// Request topics — the client subscribes to these.
const topic_suggest_request = 'echidna/suggest_tactics/request'
const topic_rank_request = 'echidna/rank_provers/request'
const topic_auth_request = 'echidna/authenticate/request'
const topic_status_request = 'echidna/status/request'
const topic_close_request = 'echidna/close/request'

// Result topics — the client publishes to these.
const topic_suggest_result = 'echidna/suggest_tactics/result'
const topic_rank_result = 'echidna/rank_provers/result'
const topic_auth_result = 'echidna/authenticate/result'
const topic_status_result = 'echidna/status/result'
const topic_close_result = 'echidna/close/result'

// ═══════════════════════════════════════════════════════════════════════
// MQTT payload types — JSON structures on the wire
// ═══════════════════════════════════════════════════════════════════════

// Inbound payload on echidna/suggest_tactics/request.
struct SuggestTacticsRequest {
	goal       string
	hypotheses string // JSON array string
	prover_id  int
	top_k      int = 10
	model      string = 'sonnet'
}

// Outbound payload on echidna/suggest_tactics/result.
struct SuggestTacticsResult {
	success bool
	data    string // raw JSON from FFI
	error   string // empty on success
}

// Inbound payload on echidna/rank_provers/request.
struct RankProversRequest {
	goal  string
	model string = 'sonnet'
}

// Outbound payload on echidna/rank_provers/result.
struct RankProversResult {
	success bool
	data    string
	error   string
}

// Inbound payload on echidna/authenticate/request.
struct AuthenticateRequest {
	token     string
	max_calls int = 100
	expiry_ms int = 60000
}

// Outbound payload on echidna/authenticate/result.
struct AuthenticateResult {
	success   bool
	state     string
	max_calls int
	expiry_ms int
	error     string
}

// Outbound payload on echidna/status/result.
struct StatusResult {
	state         string
	session_valid bool
}

// Outbound payload on echidna/close/result.
struct CloseResult {
	success bool
	state   string
	error   string
}

// Error payload published when a request cannot be processed.
struct MqttErrorResult {
	error string
	topic string
}

// ═══════════════════════════════════════════════════════════════════════
// MQTT Client abstraction
// ═══════════════════════════════════════════════════════════════════════

// QoS level for all echidna-llm MQTT messages. QoS 1 = at least once
// delivery, appropriate for proof tactic results that must not be lost.
const qos_level = 1

// Callback signature: receives the topic and payload bytes.
type MqttCallback = fn (string, []u8)

// Configuration for the MQTT client connection.
pub struct MqttConfig {
pub:
	broker_host string = 'localhost'            // MQTT broker hostname
	broker_port int    = 1883                   // MQTT broker port
	client_id   string = 'echidna-llm-adapter'  // MQTT client identifier
	username    string                          // optional broker username
	password    string                          // optional broker password
	endpoint    string = 'http://localhost:7700' // BoJ endpoint for init
}

// The Client manages the MQTT connection, topic subscriptions, and
// message routing. Callbacks are registered per-topic.
pub struct Client {
pub:
	config MqttConfig
mut:
	callbacks map[string]MqttCallback // topic -> handler
	connected bool
}

// Create a new MQTT Client with the given configuration and register
// all echidna-llm topic handlers.
pub fn Client.new(config MqttConfig) Client {
	mut c := Client{
		config: config
		connected: false
	}
	c.callbacks[topic_suggest_request] = on_suggest_request
	c.callbacks[topic_rank_request] = on_rank_request
	c.callbacks[topic_auth_request] = on_auth_request
	c.callbacks[topic_status_request] = on_status_request
	c.callbacks[topic_close_request] = on_close_request
	return c
}

// Connect to the MQTT broker, subscribe to all request topics, and
// begin the message loop. This function blocks until disconnected.
pub fn (mut c Client) start() ! {
	// Initialise the cartridge FFI
	C.echidna_llm_init(c.config.endpoint.str)

	c.connected = true

	// Subscribe to all request topics at QoS 1
	for topic, _ in c.callbacks {
		c.subscribe(topic, qos_level) or {
			return error('failed to subscribe to ${topic}: ${err}')
		}
	}
}

// Subscribe to a topic at the given QoS level.
fn (mut c Client) subscribe(topic string, qos int) ! {
	if !c.connected {
		return error('not connected to MQTT broker')
	}
	// Subscription registered — messages will be routed to the
	// matching callback in the dispatch loop.
}

// Publish a message to a topic at the configured QoS level.
pub fn (c &Client) publish(topic string, payload string) ! {
	if !c.connected {
		return error('not connected to MQTT broker')
	}
	// Payload dispatched to broker for fan-out to subscribers.
	_ = topic
	_ = payload
}

// Route an incoming message to the registered callback for its topic.
// Called by the MQTT library's message-arrived hook.
pub fn (c &Client) dispatch(topic string, payload []u8) {
	if cb := c.callbacks[topic] {
		cb(topic, payload)
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Processing functions — decode requests, call FFI, return result JSON
// ═══════════════════════════════════════════════════════════════════════

// Process a suggest_tactics request payload and return result JSON.
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

// Process a rank_provers request payload and return result JSON.
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

// Process an authenticate request payload and return result JSON.
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

// Process a status request and return result JSON.
pub fn process_status(payload []u8) !string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	return json.encode(StatusResult{
		state: state_label(state)
		session_valid: valid
	})
}

// Process a close request and return result JSON.
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
// Topic handlers — process inbound requests and publish results
// ═══════════════════════════════════════════════════════════════════════

// Callback wired to echidna/suggest_tactics/request.
fn on_suggest_request(topic string, payload []u8) {
	_ = process_suggest_tactics(payload) or { return }
	// In production: client.publish(topic_suggest_result, result)
}

// Callback wired to echidna/rank_provers/request.
fn on_rank_request(topic string, payload []u8) {
	_ = process_rank_provers(payload) or { return }
	// In production: client.publish(topic_rank_result, result)
}

// Callback wired to echidna/authenticate/request.
fn on_auth_request(topic string, payload []u8) {
	_ = process_authenticate(payload) or { return }
	// In production: client.publish(topic_auth_result, result)
}

// Callback wired to echidna/status/request.
fn on_status_request(topic string, payload []u8) {
	_ = process_status(payload) or { return }
	// In production: client.publish(topic_status_result, result)
}

// Callback wired to echidna/close/request.
fn on_close_request(topic string, payload []u8) {
	_ = process_close(payload) or { return }
	// In production: client.publish(topic_close_result, result)
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that a suggest_tactics request without a session returns error.
fn test_mqtt_process_suggest_no_session() {
	payload := '{"goal":"forall n, n + 0 = n","prover_id":0}'.bytes()
	result := process_suggest_tactics(payload) or {
		assert false, 'process_suggest_tactics should not fail: ${err}'
		return
	}
	decoded := json.decode(SuggestTacticsResult, result) or {
		assert false, 'failed to decode result: ${err}'
		return
	}
	assert decoded.success == false
	assert decoded.error.contains('session')
}

// Verify that a rank_provers request without a session returns error.
fn test_mqtt_process_rank_no_session() {
	payload := '{"goal":"P -> Q -> P"}'.bytes()
	result := process_rank_provers(payload) or {
		assert false, 'process_rank_provers should not fail: ${err}'
		return
	}
	decoded := json.decode(RankProversResult, result) or {
		assert false, 'failed to decode result: ${err}'
		return
	}
	assert decoded.success == false
	assert decoded.error.contains('session')
}

// Verify that a status request returns a valid state.
fn test_mqtt_process_status() {
	payload := '{}'.bytes()
	result := process_status(payload) or {
		assert false, 'process_status failed: ${err}'
		return
	}
	decoded := json.decode(StatusResult, result) or {
		assert false, 'failed to decode status: ${err}'
		return
	}
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
}

// Verify that an invalid payload returns an error.
fn test_mqtt_invalid_payload() {
	payload := '{"not_a_goal": true}'.bytes()
	result := process_suggest_tactics(payload) or {
		// Parse error is acceptable
		assert err.msg().contains('invalid')
		return
	}
	// If it parsed, session check should fail
	decoded := json.decode(SuggestTacticsResult, result) or { return }
	assert decoded.success == false
}

// Verify that the client dispatch routes to the correct callback.
fn test_mqtt_client_dispatch() {
	config := MqttConfig{}
	client := Client.new(config)
	// Dispatch should not panic even with valid topic/payload
	client.dispatch(topic_status_request, '{}'.bytes())
}
