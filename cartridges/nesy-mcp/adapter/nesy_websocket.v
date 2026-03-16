// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — WebSocket transport adapter.
//
// Provides a WebSocket server that exposes the NeSy harmonization engine
// over persistent bidirectional connections. Clients join the "nesy" room
// on connect and can issue text-frame commands. Harmonization results are
// broadcast to all room members so every connected dashboard sees updates
// in real time.
//
// Wire protocol (text frames):
//   /harmonize <neural_label> <symbolic_label>
//   /drift <kind>
//   /mode <name>
//   /health
//
// Responses are JSON objects on the same WebSocket connection.
// Broadcasts go to every client in the "nesy" room.

module nesy_websocket

import json
import net
import sync

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

// Map NeuralVerdict integer to its canonical label.
fn neural_label(v int) string {
	return match v {
		1 { 'probable_safe' }
		2 { 'unsure' }
		3 { 'probable_unsafe' }
		else { 'unknown' }
	}
}

// Map SymbolicVerdict integer to its canonical label.
fn symbolic_label(v int) string {
	return match v {
		1 { 'proven_safe' }
		2 { 'no_proof' }
		3 { 'proven_unsafe' }
		else { 'unknown' }
	}
}

// Map HarmonizedVerdict integer to its canonical label.
fn harmonized_label(v int) string {
	return match v {
		1 { 'certified_safe' }
		2 { 'requires_review' }
		3 { 'critical_unsafe' }
		else { 'unknown' }
	}
}

// Map ConfidenceLevel integer to its canonical label.
fn confidence_label(v int) string {
	return match v {
		1 { 'low' }
		2 { 'high' }
		3 { 'absolute' }
		else { 'unknown' }
	}
}

// Map DriftKind integer to its canonical label.
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

// Map DriftAction integer to its canonical label.
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

// Map ReasoningMode integer to its canonical label.
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
// String-to-int parsers — decode wire labels into FFI integers
// ═══════════════════════════════════════════════════════════════════════

// Parse a neural verdict label string into its integer encoding.
// Returns an error for unrecognised labels.
fn parse_neural(s string) !int {
	return match s {
		'probable_safe' { 1 }
		'unsure' { 2 }
		'probable_unsafe' { 3 }
		else { error('unknown neural verdict: ${s}') }
	}
}

// Parse a symbolic verdict label string into its integer encoding.
fn parse_symbolic(s string) !int {
	return match s {
		'proven_safe' { 1 }
		'no_proof' { 2 }
		'proven_unsafe' { 3 }
		else { error('unknown symbolic verdict: ${s}') }
	}
}

// Parse a drift kind label string into its integer encoding.
// Accepts both CamelCase and snake_case forms.
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

// Parse a reasoning mode label string into its integer encoding.
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
// WebSocket response types — serialised to JSON on the wire
// ═══════════════════════════════════════════════════════════════════════

// Response payload for /harmonize commands.
struct HarmonizeWsResponse {
	kind           string // always "harmonize"
	neural_input   string
	symbolic_input string
	verdict        string
	confidence     string
	symbolic_wins  bool
}

// Response payload for /drift commands.
struct DriftWsResponse {
	kind               string // always "drift"
	drift              string
	severity           int
	urgent             bool
	recommended_action string
}

// Response payload for /mode commands.
struct ModeWsResponse {
	kind          string // always "mode"
	mode          string
	uses_symbolic bool
	uses_neural   bool
	is_hybrid     bool
}

// Response payload for /health commands.
struct HealthWsResponse {
	kind    string // always "health"
	status  string
	adapter string
}

// Error response sent when a command cannot be processed.
struct ErrorWsResponse {
	kind    string // always "error"
	message string
}

// ═══════════════════════════════════════════════════════════════════════
// Room-based Broker — manages connected clients and broadcasts
// ═══════════════════════════════════════════════════════════════════════

// Represents a single connected WebSocket client with a send channel.
struct WsClient {
	id   int
mut:
	conn &net.TcpConn
}

// The Broker manages rooms of WebSocket clients. All mutations are
// guarded by a sync.Mutex so the server can accept connections from
// multiple threads safely.
struct Broker {
mut:
	mu      sync.Mutex
	rooms   map[string][]&WsClient // room name -> list of clients
	next_id int                     // monotonic client ID counter
}

// Create a new empty Broker with the mutex initialised.
fn Broker.new() Broker {
	return Broker{
		rooms: map[string][]&WsClient{}
		next_id: 0
	}
}

// Add a client to a named room. Returns the assigned client ID.
// Thread-safe: acquires the broker mutex.
fn (mut b Broker) join(room string, conn &net.TcpConn) int {
	b.mu.@lock()
	defer { b.mu.unlock() }

	id := b.next_id
	b.next_id += 1

	client := &WsClient{
		id: id
		conn: conn
	}

	if room in b.rooms {
		b.rooms[room] << client
	} else {
		b.rooms[room] = [client]
	}
	return id
}

// Remove a client from a named room by its ID.
// Thread-safe: acquires the broker mutex.
fn (mut b Broker) leave(room string, client_id int) {
	b.mu.@lock()
	defer { b.mu.unlock() }

	if room in b.rooms {
		b.rooms[room] = b.rooms[room].filter(it.id != client_id)
	}
}

// Broadcast a text-frame message to every client in a named room.
// Silently skips clients whose connection has errored.
// Thread-safe: acquires the broker mutex for the client list snapshot.
fn (mut b Broker) broadcast(room string, msg string) {
	b.mu.@lock()
	clients := if room in b.rooms { b.rooms[room].clone() } else { []&WsClient{} }
	b.mu.unlock()

	for c in clients {
		c.conn.write(msg.bytes()) or { continue }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// WebSocket server configuration
// ═══════════════════════════════════════════════════════════════════════

// Configuration for the NeSy WebSocket server.
pub struct WsServerConfig {
pub:
	port int = 9801 // TCP port to bind; override via config or env
}

// ═══════════════════════════════════════════════════════════════════════
// Command dispatcher — parses incoming text frames and routes them
// ═══════════════════════════════════════════════════════════════════════

// Dispatch a single text-frame command and return the JSON response.
// Also returns whether the result should be broadcast to the room
// (true for harmonize results, false for health checks).
pub fn dispatch_command(raw string) (string, bool) {
	parts := raw.trim_space().split(' ')
	if parts.len == 0 {
		return json.encode(ErrorWsResponse{ kind: 'error', message: 'empty command' }), false
	}

	cmd := parts[0]
	match cmd {
		'/harmonize' {
			// Expect: /harmonize <neural> <symbolic>
			if parts.len < 3 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'usage: /harmonize <neural_verdict> <symbolic_verdict>'
				}), false
			}
			neural := parse_neural(parts[1]) or {
				return json.encode(ErrorWsResponse{ kind: 'error', message: err.msg() }), false
			}
			symbolic := parse_symbolic(parts[2]) or {
				return json.encode(ErrorWsResponse{ kind: 'error', message: err.msg() }), false
			}
			result := C.nesy_harmonize(neural, symbolic)
			conf := C.nesy_confidence(neural, symbolic)
			resp := HarmonizeWsResponse{
				kind: 'harmonize'
				neural_input: neural_label(neural)
				symbolic_input: symbolic_label(symbolic)
				verdict: harmonized_label(result)
				confidence: confidence_label(conf)
				symbolic_wins: symbolic != 2
			}
			// Harmonize results are broadcast to all room members
			return json.encode(resp), true
		}
		'/drift' {
			// Expect: /drift <kind>
			if parts.len < 2 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'usage: /drift <kind>'
				}), false
			}
			drift_int := parse_drift(parts[1]) or {
				return json.encode(ErrorWsResponse{ kind: 'error', message: err.msg() }), false
			}
			action := C.nesy_recommend_drift_action(drift_int)
			resp := DriftWsResponse{
				kind: 'drift'
				drift: drift_kind_label(drift_int)
				severity: drift_int
				urgent: C.nesy_drift_is_urgent(drift_int) == 1
				recommended_action: drift_action_label(action)
			}
			return json.encode(resp), true
		}
		'/mode' {
			// Expect: /mode <name>
			if parts.len < 2 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'usage: /mode <name>'
				}), false
			}
			mode_int := parse_mode(parts[1]) or {
				return json.encode(ErrorWsResponse{ kind: 'error', message: err.msg() }), false
			}
			sym := C.nesy_mode_uses_symbolic(mode_int) == 1
			neur := C.nesy_mode_uses_neural(mode_int) == 1
			resp := ModeWsResponse{
				kind: 'mode'
				mode: reasoning_mode_label(mode_int)
				uses_symbolic: sym
				uses_neural: neur
				is_hybrid: sym && neur
			}
			return json.encode(resp), false
		}
		'/health' {
			resp := HealthWsResponse{
				kind: 'health'
				status: 'ok'
				adapter: 'nesy_websocket'
			}
			return json.encode(resp), false
		}
		else {
			return json.encode(ErrorWsResponse{
				kind: 'error'
				message: 'unknown command: ${cmd}. Use /harmonize, /drift, /mode, or /health'
			}), false
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Server lifecycle — start, accept, handle
// ═══════════════════════════════════════════════════════════════════════

// Start the NeSy WebSocket server. Binds to the configured port and
// enters an accept loop. Each connection is auto-joined to the "nesy"
// room. This function blocks until the server is shut down.
pub fn start_server(config WsServerConfig) ! {
	mut broker := Broker.new()
	mut listener := net.listen_tcp(.ip, ':${config.port}') or {
		return error('failed to bind WebSocket server on port ${config.port}: ${err}')
	}
	defer { listener.close() or {} }

	for {
		mut conn := listener.accept() or { continue }
		client_id := broker.join('nesy', &conn)
		handle_connection(mut &broker, mut conn, client_id)
	}
}

// Handle a single WebSocket client connection. Reads text frames in a
// loop, dispatches commands, and broadcasts results when appropriate.
// Removes the client from the "nesy" room on disconnect.
fn handle_connection(mut broker &Broker, mut conn net.TcpConn, client_id int) {
	defer { broker.leave('nesy', client_id) }

	mut buf := []u8{len: 4096}
	for {
		n := conn.read(mut buf) or { break }
		if n == 0 {
			break
		}
		raw := buf[..n].bytestr()
		response, should_broadcast := dispatch_command(raw)

		// Always send the response to the requesting client
		conn.write(response.bytes()) or { break }

		// If the command produced a broadcastable result, fan it out
		if should_broadcast {
			broker.broadcast('nesy', response)
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that the /harmonize command produces the correct JSON response
// when symbolic proof overrides neural uncertainty.
fn test_dispatch_harmonize() {
	response, should_broadcast := dispatch_command('/harmonize unsure proven_safe')
	assert should_broadcast == true

	decoded := json.decode(HarmonizeWsResponse, response) or {
		assert false, 'failed to decode harmonize response: ${err}'
		return
	}
	assert decoded.kind == 'harmonize'
	assert decoded.neural_input == 'unsure'
	assert decoded.symbolic_input == 'proven_safe'
	assert decoded.symbolic_wins == true
}

// Verify that the /drift command returns a valid drift analysis.
fn test_dispatch_drift() {
	response, should_broadcast := dispatch_command('/drift catastrophic')
	assert should_broadcast == true

	decoded := json.decode(DriftWsResponse, response) or {
		assert false, 'failed to decode drift response: ${err}'
		return
	}
	assert decoded.kind == 'drift'
	assert decoded.drift == 'CatastrophicDrift'
	assert decoded.severity == 5
	assert decoded.urgent == true
}

// Verify that the /mode command returns correct mode metadata.
fn test_dispatch_mode() {
	response, _ := dispatch_command('/mode ensemble')
	decoded := json.decode(ModeWsResponse, response) or {
		assert false, 'failed to decode mode response: ${err}'
		return
	}
	assert decoded.kind == 'mode'
	assert decoded.mode == 'Ensemble'
	assert decoded.is_hybrid == true
}

// Verify that /health returns a green status.
fn test_dispatch_health() {
	response, should_broadcast := dispatch_command('/health')
	assert should_broadcast == false

	decoded := json.decode(HealthWsResponse, response) or {
		assert false, 'failed to decode health response: ${err}'
		return
	}
	assert decoded.kind == 'health'
	assert decoded.status == 'ok'
	assert decoded.adapter == 'nesy_websocket'
}

// Verify that an unknown command produces an error response.
fn test_dispatch_unknown_command() {
	response, should_broadcast := dispatch_command('/explode')
	assert should_broadcast == false

	decoded := json.decode(ErrorWsResponse, response) or {
		assert false, 'failed to decode error response: ${err}'
		return
	}
	assert decoded.kind == 'error'
	assert decoded.message.contains('unknown command')
}
