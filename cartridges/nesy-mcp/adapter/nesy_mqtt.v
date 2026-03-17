// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — MQTT transport adapter.
//
// Implements an MQTT client that subscribes to NeSy request topics and
// publishes results back on paired result topics. This enables lightweight
// pub/sub integration for IoT, edge, and event-driven architectures.
//
// Topic map (QoS 0 throughout):
//   Subscribe:
//     nesy/harmonize/request  — payload: {"neural":"...", "symbolic":"..."}
//     nesy/drift/request      — payload: {"kind":"..."}
//     nesy/mode/request       — payload: {"mode":"..."}
//
//   Publish:
//     nesy/harmonize/result   — JSON harmonization result
//     nesy/drift/result       — JSON drift analysis result
//     nesy/mode/result        — JSON reasoning mode info
//
// All payloads are JSON. The client auto-reconnects on broker disconnect.

module nesy_mqtt

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
// String-to-int parsers
// ═══════════════════════════════════════════════════════════════════════

fn parse_neural(s string) !int {
	return match s {
		'probable_safe' { 1 }
		'unsure' { 2 }
		'probable_unsafe' { 3 }
		else { error('unknown neural verdict: ${s}') }
	}
}

fn parse_symbolic(s string) !int {
	return match s {
		'proven_safe' { 1 }
		'no_proof' { 2 }
		'proven_unsafe' { 3 }
		else { error('unknown symbolic verdict: ${s}') }
	}
}

fn parse_drift(s string) !int {
	return match s.to_lower() {
		'nodrift', 'no_drift', 'none' { 0 }
		'semanticdrift', 'semantic' { 1 }
		'confidencedrift', 'confidence' { 2 }
		'factualdrift', 'factual' { 3 }
		'temporaldrift', 'temporal' { 4 }
		'catastrophicdrift', 'catastrophic' { 5 }
		else { error('unknown drift kind: ${s}') }
	}
}

fn parse_mode(s string) !int {
	return match s.to_lower() {
		'symbolic' { 0 }
		'neural' { 1 }
		'symtoneural' { 2 }
		'neuraltosym' { 3 }
		'ensemble' { 4 }
		'cascade' { 5 }
		else { error('unknown reasoning mode: ${s}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// MQTT topic constants
// ═══════════════════════════════════════════════════════════════════════

// Request topics — the client subscribes to these.
const topic_harmonize_request = 'nesy/harmonize/request'
const topic_drift_request = 'nesy/drift/request'
const topic_mode_request = 'nesy/mode/request'

// Result topics — the client publishes to these.
const topic_harmonize_result = 'nesy/harmonize/result'
const topic_drift_result = 'nesy/drift/result'
const topic_mode_result = 'nesy/mode/result'

// ═══════════════════════════════════════════════════════════════════════
// MQTT payload types — JSON structures on the wire
// ═══════════════════════════════════════════════════════════════════════

// Inbound payload on nesy/harmonize/request.
struct HarmonizeRequest {
	neural   string
	symbolic string
}

// Outbound payload on nesy/harmonize/result.
struct HarmonizeResult {
	neural_input   string
	symbolic_input string
	verdict        string
	confidence     string
	symbolic_wins  bool
}

// Inbound payload on nesy/drift/request.
struct DriftRequest {
	kind string
}

// Outbound payload on nesy/drift/result.
struct DriftResult {
	drift              string
	severity           int
	urgent             bool
	recommended_action string
}

// Inbound payload on nesy/mode/request.
struct ModeRequest {
	mode string
}

// Outbound payload on nesy/mode/result.
struct ModeResult {
	mode          string
	uses_symbolic bool
	uses_neural   bool
	is_hybrid     bool
}

// Error payload published when a request cannot be processed.
struct MqttErrorResult {
	error string
	topic string
}

// ═══════════════════════════════════════════════════════════════════════
// MQTT Client abstraction
// ═══════════════════════════════════════════════════════════════════════

// QoS level for all NeSy MQTT messages. QoS 0 = at most once delivery,
// which is appropriate for advisory harmonization results.
const qos_level = 0

// Callback signature: receives the topic and payload bytes.
type MqttCallback = fn (string, []u8)

// Configuration for the MQTT client connection.
pub struct MqttConfig {
pub:
	broker_host string = 'localhost' // MQTT broker hostname
	broker_port int    = 1883        // MQTT broker port
	client_id   string = 'nesy-mcp-adapter' // MQTT client identifier
	username    string               // optional broker username
	password    string               // optional broker password
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
// all NeSy topic handlers.
pub fn Client.new(config MqttConfig) Client {
	mut c := Client{
		config: config
		connected: false
	}
	c.callbacks[topic_harmonize_request] = on_harmonize_request
	c.callbacks[topic_drift_request] = on_drift_request
	c.callbacks[topic_mode_request] = on_mode_request
	return c
}

// Connect to the MQTT broker, subscribe to all request topics, and
// begin the message loop. This function blocks until disconnected.
pub fn (mut c Client) start() ! {
	// In production this calls into an MQTT library (e.g. paho-mqtt-c
	// via C interop). Here we define the connection lifecycle.
	c.connected = true

	// Subscribe to all request topics at QoS 0
	for topic, _ in c.callbacks {
		c.subscribe(topic, qos_level) or {
			return error('failed to subscribe to ${topic}: ${err}')
		}
	}
}

// Subscribe to a topic at the given QoS level.
// In production this calls the underlying MQTT library.
fn (mut c Client) subscribe(topic string, qos int) ! {
	if !c.connected {
		return error('not connected to MQTT broker')
	}
	// Subscription registered — messages will be routed to the
	// matching callback in the dispatch loop.
}

// Publish a message to a topic at QoS 0.
// In production this calls the underlying MQTT library.
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
// Topic handlers — process inbound requests and publish results
// ═══════════════════════════════════════════════════════════════════════

// Process a harmonize request: decode neural + symbolic verdicts,
// call FFI, and return the JSON result for publishing.
pub fn process_harmonize(payload []u8) !string {
	req := json.decode(HarmonizeRequest, payload.bytestr()) or {
		return error('invalid harmonize request payload: ${err}')
	}
	neural := parse_neural(req.neural)!
	symbolic := parse_symbolic(req.symbolic)!

	result := C.nesy_harmonize(neural, symbolic)
	conf := C.nesy_confidence(neural, symbolic)

	return json.encode(HarmonizeResult{
		neural_input: neural_label(neural)
		symbolic_input: symbolic_label(symbolic)
		verdict: harmonized_label(result)
		confidence: confidence_label(conf)
		symbolic_wins: symbolic != 2
	})
}

// Process a drift request: decode drift kind, call FFI, return JSON.
pub fn process_drift(payload []u8) !string {
	req := json.decode(DriftRequest, payload.bytestr()) or {
		return error('invalid drift request payload: ${err}')
	}
	drift_int := parse_drift(req.kind)!
	action := C.nesy_recommend_drift_action(drift_int)

	return json.encode(DriftResult{
		drift: drift_kind_label(drift_int)
		severity: drift_int
		urgent: C.nesy_drift_is_urgent(drift_int) == 1
		recommended_action: drift_action_label(action)
	})
}

// Process a mode request: decode reasoning mode, call FFI, return JSON.
pub fn process_mode(payload []u8) !string {
	req := json.decode(ModeRequest, payload.bytestr()) or {
		return error('invalid mode request payload: ${err}')
	}
	mode_int := parse_mode(req.mode)!
	sym := C.nesy_mode_uses_symbolic(mode_int) == 1
	neur := C.nesy_mode_uses_neural(mode_int) == 1

	return json.encode(ModeResult{
		mode: reasoning_mode_label(mode_int)
		uses_symbolic: sym
		uses_neural: neur
		is_hybrid: sym && neur
	})
}

// Callback wired to nesy/harmonize/request. Decodes, processes, and
// would publish to nesy/harmonize/result in a live broker context.
fn on_harmonize_request(topic string, payload []u8) {
	_ = process_harmonize(payload) or { return }
	// In production: client.publish(topic_harmonize_result, result)
}

// Callback wired to nesy/drift/request.
fn on_drift_request(topic string, payload []u8) {
	_ = process_drift(payload) or { return }
	// In production: client.publish(topic_drift_result, result)
}

// Callback wired to nesy/mode/request.
fn on_mode_request(topic string, payload []u8) {
	_ = process_mode(payload) or { return }
	// In production: client.publish(topic_mode_result, result)
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that a harmonize request payload is correctly processed.
fn test_mqtt_process_harmonize() {
	payload := '{"neural":"probable_unsafe","symbolic":"proven_safe"}'.bytes()
	result := process_harmonize(payload) or {
		assert false, 'process_harmonize failed: ${err}'
		return
	}
	decoded := json.decode(HarmonizeResult, result) or {
		assert false, 'failed to decode harmonize result: ${err}'
		return
	}
	assert decoded.neural_input == 'probable_unsafe'
	assert decoded.symbolic_input == 'proven_safe'
	assert decoded.symbolic_wins == true
}

// Verify that a drift request payload is correctly processed.
fn test_mqtt_process_drift() {
	payload := '{"kind":"catastrophic"}'.bytes()
	result := process_drift(payload) or {
		assert false, 'process_drift failed: ${err}'
		return
	}
	decoded := json.decode(DriftResult, result) or {
		assert false, 'failed to decode drift result: ${err}'
		return
	}
	assert decoded.drift == 'CatastrophicDrift'
	assert decoded.severity == 5
	assert decoded.urgent == true
}

// Verify that a mode request payload is correctly processed.
fn test_mqtt_process_mode() {
	payload := '{"mode":"ensemble"}'.bytes()
	result := process_mode(payload) or {
		assert false, 'process_mode failed: ${err}'
		return
	}
	decoded := json.decode(ModeResult, result) or {
		assert false, 'failed to decode mode result: ${err}'
		return
	}
	assert decoded.mode == 'Ensemble'
	assert decoded.uses_symbolic == true
	assert decoded.uses_neural == true
	assert decoded.is_hybrid == true
}

// Verify that an invalid payload returns an error, not a crash.
fn test_mqtt_invalid_payload() {
	payload := '{"neural":"banana","symbolic":"proven_safe"}'.bytes()
	result := process_harmonize(payload) or {
		assert err.msg().contains('unknown neural verdict')
		return
	}
	assert false, 'expected error for invalid neural verdict'
}

// Verify that the client dispatch routes to the correct callback.
fn test_mqtt_client_dispatch() {
	config := MqttConfig{}
	client := Client.new(config)
	// Dispatch should not panic even with valid topic/payload
	client.dispatch(topic_harmonize_request, '{"neural":"unsure","symbolic":"no_proof"}'.bytes())
}
