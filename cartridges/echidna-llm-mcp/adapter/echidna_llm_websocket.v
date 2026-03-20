// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — WebSocket transport adapter.
//
// Provides a WebSocket server that exposes the ECHIDNA frontier LLM tactic
// advisory over persistent bidirectional connections. Clients join the
// "echidna-llm" room on connect and can issue text-frame commands.
// Tactic suggestions and prover rankings are broadcast to all room members
// so every connected dashboard sees updates in real time.
//
// Wire protocol (text frames):
//   /suggest_tactics <goal> <prover_id> [model]
//   /rank_provers <goal> [model]
//   /authenticate <token> [max_calls] [expiry_ms]
//   /status
//   /close
//   /health
//
// Responses are JSON objects on the same WebSocket connection.
// Broadcasts go to every client in the "echidna-llm" room.

module echidna_llm_websocket

import json
import net
import sync

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
// Returns 1 if valid, 0 otherwise.
fn C.echidna_llm_session_valid() int

// Suggest tactics for a proof goal. Returns heap-allocated JSON.
// Caller MUST free the result with echidna_llm_free.
fn C.echidna_llm_suggest_tactics(goal &u8, goal_len int, hyp &u8, hyp_len int, prover_id int, top_k int, model int) &u8

// Rank provers for a proof goal. Returns heap-allocated JSON.
// Caller MUST free the result with echidna_llm_free.
fn C.echidna_llm_rank_provers(goal &u8, goal_len int, model int) &u8

// Free a string returned by any echidna_llm_* function.
fn C.echidna_llm_free(ptr &u8)

// Check if a state transition is valid. Returns 1 if valid, 0 if not.
fn C.echidna_llm_can_transition(from int, to int) int

// Check if an operation is advisory (always returns 1).
fn C.echidna_llm_is_advisory(op int) int

// ═══════════════════════════════════════════════════════════════════════
// Label helpers — convert integer encodings to human-readable strings
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
		else { 1 } // default to sonnet
	}
}

// Map ModelTier integer back to its canonical label.
fn model_label(v int) string {
	return match v {
		0 { 'haiku' }
		2 { 'opus' }
		else { 'sonnet' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// WebSocket response types — serialised to JSON on the wire
// ═══════════════════════════════════════════════════════════════════════

// Response payload for /suggest_tactics commands.
struct SuggestTacticsWsResponse {
	kind    string // always "suggest_tactics"
	success bool
	data    string // raw JSON from FFI
}

// Response payload for /rank_provers commands.
struct RankProversWsResponse {
	kind    string // always "rank_provers"
	success bool
	data    string // raw JSON from FFI
}

// Response payload for /authenticate commands.
struct AuthenticateWsResponse {
	kind      string // always "authenticate"
	success   bool
	state     string
	max_calls int
	expiry_ms int
}

// Response payload for /status commands.
struct StatusWsResponse {
	kind          string // always "status"
	state         string
	session_valid bool
}

// Response payload for /close commands.
struct CloseWsResponse {
	kind    string // always "close"
	success bool
	state   string
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

// Represents a single connected WebSocket client.
struct WsClient {
	id int
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

// Configuration for the echidna-llm WebSocket server.
pub struct WsServerConfig {
pub:
	port     int    = 9810 // TCP port to bind; override via config or env
	endpoint string = 'http://localhost:7700' // BoJ endpoint for init
}

// ═══════════════════════════════════════════════════════════════════════
// Command dispatcher — parses incoming text frames and routes them
// ═══════════════════════════════════════════════════════════════════════

// Dispatch a single text-frame command and return the JSON response.
// Also returns whether the result should be broadcast to the room
// (true for tactic suggestions and prover rankings, false for status).
pub fn dispatch_command(raw string) (string, bool) {
	parts := raw.trim_space().split(' ')
	if parts.len == 0 {
		return json.encode(ErrorWsResponse{ kind: 'error', message: 'empty command' }), false
	}

	cmd := parts[0]
	match cmd {
		'/suggest_tactics' {
			// Expect: /suggest_tactics <goal> <prover_id> [model]
			if parts.len < 3 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'usage: /suggest_tactics <goal> <prover_id> [model]'
				}), false
			}

			if C.echidna_llm_session_valid() != 1 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'session expired or call limit reached'
				}), false
			}

			goal := parts[1]
			prover_id := parts[2].int()
			model := if parts.len > 3 { model_from_string(parts[3]) } else { 1 }
			hypotheses := '[]'

			result_ptr := C.echidna_llm_suggest_tactics(
				goal.str, goal.len,
				hypotheses.str, hypotheses.len,
				prover_id, 10, model,
			)

			if result_ptr == unsafe { nil } {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'tactic suggestion failed — session may have expired'
				}), false
			}

			result_str := unsafe { cstring_to_vstring(result_ptr) }
			C.echidna_llm_free(result_ptr)

			resp := SuggestTacticsWsResponse{
				kind: 'suggest_tactics'
				success: true
				data: result_str
			}
			// Tactic suggestions are broadcast to all room members
			return json.encode(resp), true
		}
		'/rank_provers' {
			// Expect: /rank_provers <goal> [model]
			if parts.len < 2 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'usage: /rank_provers <goal> [model]'
				}), false
			}

			if C.echidna_llm_session_valid() != 1 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'session expired or call limit reached'
				}), false
			}

			goal := parts[1]
			model := if parts.len > 2 { model_from_string(parts[2]) } else { 1 }

			result_ptr := C.echidna_llm_rank_provers(goal.str, goal.len, model)

			if result_ptr == unsafe { nil } {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'prover ranking failed'
				}), false
			}

			result_str := unsafe { cstring_to_vstring(result_ptr) }
			C.echidna_llm_free(result_ptr)

			resp := RankProversWsResponse{
				kind: 'rank_provers'
				success: true
				data: result_str
			}
			// Prover rankings are broadcast to all room members
			return json.encode(resp), true
		}
		'/authenticate' {
			// Expect: /authenticate <token> [max_calls] [expiry_ms]
			if parts.len < 2 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'usage: /authenticate <token> [max_calls] [expiry_ms]'
				}), false
			}

			token := parts[1]
			max_calls := if parts.len > 2 { parts[2].int() } else { 100 }
			expiry_ms := if parts.len > 3 { parts[3].int() } else { 60000 }

			result := C.echidna_llm_authenticate(token.str, token.len, max_calls, expiry_ms)
			if result != 0 {
				msg := match result {
					-1 { 'invalid state transition — session already active' }
					-2 { 'max_calls must be between 1 and 1000' }
					-3 { 'expiry_ms must be positive' }
					else { 'authentication failed with code ${result}' }
				}
				return json.encode(ErrorWsResponse{ kind: 'error', message: msg }), false
			}

			C.echidna_llm_start_operating()
			state := C.echidna_llm_get_state()

			resp := AuthenticateWsResponse{
				kind: 'authenticate'
				success: true
				state: state_label(state)
				max_calls: max_calls
				expiry_ms: expiry_ms
			}
			return json.encode(resp), false
		}
		'/status' {
			state := C.echidna_llm_get_state()
			valid := C.echidna_llm_session_valid() == 1

			resp := StatusWsResponse{
				kind: 'status'
				state: state_label(state)
				session_valid: valid
			}
			return json.encode(resp), false
		}
		'/close' {
			result := C.echidna_llm_close()
			state := C.echidna_llm_get_state()

			if result != 0 {
				return json.encode(ErrorWsResponse{
					kind: 'error'
					message: 'cannot close — no active session'
				}), false
			}

			resp := CloseWsResponse{
				kind: 'close'
				success: true
				state: state_label(state)
			}
			return json.encode(resp), false
		}
		'/health' {
			resp := HealthWsResponse{
				kind: 'health'
				status: 'ok'
				adapter: 'echidna_llm_websocket'
			}
			return json.encode(resp), false
		}
		else {
			return json.encode(ErrorWsResponse{
				kind: 'error'
				message: 'unknown command: ${cmd}. Use /suggest_tactics, /rank_provers, /authenticate, /status, /close, or /health'
			}), false
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Server lifecycle — start, accept, handle
// ═══════════════════════════════════════════════════════════════════════

// Start the echidna-llm WebSocket server. Binds to the configured port
// and enters an accept loop. Each connection is auto-joined to the
// "echidna-llm" room. This function blocks until the server is shut down.
pub fn start_server(config WsServerConfig) ! {
	// Initialise the cartridge FFI
	C.echidna_llm_init(config.endpoint.str)

	mut broker := Broker.new()
	mut listener := net.listen_tcp(.ip, ':${config.port}') or {
		return error('failed to bind WebSocket server on port ${config.port}: ${err}')
	}
	defer { listener.close() or {} }

	for {
		mut conn := listener.accept() or { continue }
		client_id := broker.join('echidna-llm', &conn)
		handle_connection(mut &broker, mut conn, client_id)
	}
}

// Handle a single WebSocket client connection. Reads text frames in a
// loop, dispatches commands, and broadcasts results when appropriate.
// Removes the client from the "echidna-llm" room on disconnect.
fn handle_connection(mut broker &Broker, mut conn net.TcpConn, client_id int) {
	defer { broker.leave('echidna-llm', client_id) }

	mut buf := []u8{len: 65536} // 64 KiB — goals can be large
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
			broker.broadcast('echidna-llm', response)
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that /suggest_tactics without a session returns a session error.
fn test_dispatch_suggest_no_session() {
	response, should_broadcast := dispatch_command('/suggest_tactics "forall n, n + 0 = n" 0 sonnet')
	assert should_broadcast == false
	decoded := json.decode(ErrorWsResponse, response) or {
		assert false, 'failed to decode error response: ${err}'
		return
	}
	assert decoded.kind == 'error'
	assert decoded.message.contains('session')
}

// Verify that /rank_provers without a session returns a session error.
fn test_dispatch_rank_no_session() {
	response, should_broadcast := dispatch_command('/rank_provers "P -> Q -> P" sonnet')
	assert should_broadcast == false
	decoded := json.decode(ErrorWsResponse, response) or {
		assert false, 'failed to decode error response: ${err}'
		return
	}
	assert decoded.kind == 'error'
	assert decoded.message.contains('session')
}

// Verify that /status returns a valid state response.
fn test_dispatch_status() {
	response, should_broadcast := dispatch_command('/status')
	assert should_broadcast == false
	decoded := json.decode(StatusWsResponse, response) or {
		assert false, 'failed to decode status response: ${err}'
		return
	}
	assert decoded.kind == 'status'
	// State should be one of the known labels
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
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
	assert decoded.adapter == 'echidna_llm_websocket'
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

// Verify that /authenticate with missing token returns usage error.
fn test_dispatch_authenticate_missing_token() {
	response, _ := dispatch_command('/authenticate')
	decoded := json.decode(ErrorWsResponse, response) or {
		assert false, 'failed to decode error response: ${err}'
		return
	}
	assert decoded.kind == 'error'
	assert decoded.message.contains('usage')
}
