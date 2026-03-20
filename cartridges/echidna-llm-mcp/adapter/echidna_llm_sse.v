// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — Server-Sent Events (SSE) transport adapter.
//
// Implements an SSE server that streams ECHIDNA frontier LLM tactic advisory
// events to connected clients. Clients connect via HTTP GET and receive a
// persistent text/event-stream. POST requests on paired endpoints trigger
// operations, with results pushed to all SSE subscribers.
//
// This is the MCP-native transport for Claude Desktop, Glama, and Cursor
// integrations. The SSE stream carries structured events that the MCP host
// can parse directly.
//
// Event types:
//   suggest_tactics — tactic suggestion results (broadcast)
//   rank_provers    — prover ranking results (broadcast)
//   authenticate    — session creation confirmation
//   status          — current session state
//   close           — session close confirmation
//   error           — error details
//   heartbeat       — keepalive (every 30s)
//
// Endpoints:
//   GET  /echidna-llm/events    — SSE event stream
//   POST /echidna-llm/suggest   — trigger tactic suggestion
//   POST /echidna-llm/rank      — trigger prover ranking
//   POST /echidna-llm/auth      — create ephemeral session
//   POST /echidna-llm/close     — close session
//   GET  /echidna-llm/status    — get session state (also SSE event)
//   GET  /echidna-llm/health    — health check (not SSE)

module echidna_llm_sse

import json
import net
import sync
import time

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
// SSE Event formatting — follows the W3C EventSource specification
// ═══════════════════════════════════════════════════════════════════════

// Format an SSE event with optional id. Each field is terminated by \n
// and the event is terminated by \n\n.
pub fn format_sse_event(event_type string, data string, id string) string {
	mut lines := []string{}
	if id.len > 0 {
		lines << 'id: ${id}'
	}
	lines << 'event: ${event_type}'
	// Data may contain newlines — each line must be prefixed with "data: "
	for line in data.split('\n') {
		lines << 'data: ${line}'
	}
	lines << '' // trailing blank line
	lines << '' // double newline terminates the event
	return lines.join('\n')
}

// Format a heartbeat comment. SSE comments start with ":" and keep
// the connection alive through proxies and load balancers.
pub fn format_heartbeat() string {
	return ': heartbeat ${time.now().unix()}\n\n'
}

// ═══════════════════════════════════════════════════════════════════════
// SSE payload types — serialised to JSON in the "data:" field
// ═══════════════════════════════════════════════════════════════════════

// Payload for suggest_tactics events.
struct SuggestTacticsEvent {
	success bool
	data    string // raw JSON from FFI
}

// Payload for rank_provers events.
struct RankProversEvent {
	success bool
	data    string
}

// Payload for authenticate events.
struct AuthenticateEvent {
	success   bool
	state     string
	max_calls int
	expiry_ms int
	error     string
}

// Payload for status events.
struct StatusEvent {
	state         string
	session_valid bool
}

// Payload for close events.
struct CloseEvent {
	success bool
	state   string
	error   string
}

// Payload for error events.
struct ErrorEvent {
	message string
}

// Payload for health check (not SSE, returned as plain JSON).
struct HealthResponse {
	status  string
	adapter string
}

// ═══════════════════════════════════════════════════════════════════════
// SSE request types — parsed from POST bodies
// ═══════════════════════════════════════════════════════════════════════

// POST body for /echidna-llm/suggest.
struct SuggestRequest {
	goal       string
	hypotheses string
	prover_id  int
	top_k      int = 10
	model      string = 'sonnet'
}

// POST body for /echidna-llm/rank.
struct RankRequest {
	goal  string
	model string = 'sonnet'
}

// POST body for /echidna-llm/auth.
struct AuthRequest {
	token     string
	max_calls int = 100
	expiry_ms int = 60000
}

// ═══════════════════════════════════════════════════════════════════════
// Client registry — tracks connected SSE subscribers
// ═══════════════════════════════════════════════════════════════════════

// A connected SSE client with its TCP connection.
struct SseClient {
	id int
mut:
	conn      &net.TcpConn
	connected bool
}

// The Registry manages all connected SSE clients. Thread-safe via mutex.
struct Registry {
mut:
	mu      sync.Mutex
	clients []&SseClient
	next_id int
	event_counter int // monotonic event ID for SSE "id:" field
}

// Create a new empty Registry.
fn Registry.new() Registry {
	return Registry{
		clients: []&SseClient{}
		next_id: 0
		event_counter: 0
	}
}

// Register a new SSE client. Returns the assigned client ID.
fn (mut r Registry) add(conn &net.TcpConn) int {
	r.mu.@lock()
	defer { r.mu.unlock() }

	id := r.next_id
	r.next_id += 1

	r.clients << &SseClient{
		id: id
		conn: conn
		connected: true
	}
	return id
}

// Remove a client by ID.
fn (mut r Registry) remove(client_id int) {
	r.mu.@lock()
	defer { r.mu.unlock() }
	r.clients = r.clients.filter(it.id != client_id)
}

// Broadcast an SSE event to all connected clients. Returns the event
// ID that was assigned.
fn (mut r Registry) broadcast(event_type string, data string) int {
	r.mu.@lock()
	r.event_counter += 1
	eid := r.event_counter
	snapshot := r.clients.clone()
	r.mu.unlock()

	event_str := format_sse_event(event_type, data, '${eid}')
	for c in snapshot {
		if c.connected {
			c.conn.write(event_str.bytes()) or { continue }
		}
	}
	return eid
}

// Send a heartbeat to all connected clients.
fn (mut r Registry) heartbeat() {
	r.mu.@lock()
	snapshot := r.clients.clone()
	r.mu.unlock()

	hb := format_heartbeat()
	for c in snapshot {
		if c.connected {
			c.conn.write(hb.bytes()) or { continue }
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Operation processors — called by HTTP handlers, broadcast via SSE
// ═══════════════════════════════════════════════════════════════════════

// Process a suggest_tactics request and return the SSE event data JSON.
pub fn process_suggest_tactics(body string) (string, string) {
	req := json.decode(SuggestRequest, body) or {
		evt := json.encode(ErrorEvent{ message: 'invalid request: ${err}' })
		return evt, 'error'
	}

	if C.echidna_llm_session_valid() != 1 {
		evt := json.encode(ErrorEvent{ message: 'session expired or call limit reached' })
		return evt, 'error'
	}

	model := model_from_string(req.model)
	hypotheses := if req.hypotheses.len > 0 { req.hypotheses } else { '[]' }

	result_ptr := C.echidna_llm_suggest_tactics(
		req.goal.str, req.goal.len,
		hypotheses.str, hypotheses.len,
		req.prover_id, req.top_k, model,
	)

	if result_ptr == unsafe { nil } {
		evt := json.encode(ErrorEvent{ message: 'tactic suggestion failed' })
		return evt, 'error'
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	evt := json.encode(SuggestTacticsEvent{ success: true, data: result_str })
	return evt, 'suggest_tactics'
}

// Process a rank_provers request and return the SSE event data JSON.
pub fn process_rank_provers(body string) (string, string) {
	req := json.decode(RankRequest, body) or {
		evt := json.encode(ErrorEvent{ message: 'invalid request: ${err}' })
		return evt, 'error'
	}

	if C.echidna_llm_session_valid() != 1 {
		evt := json.encode(ErrorEvent{ message: 'session expired or call limit reached' })
		return evt, 'error'
	}

	model := model_from_string(req.model)
	result_ptr := C.echidna_llm_rank_provers(req.goal.str, req.goal.len, model)

	if result_ptr == unsafe { nil } {
		evt := json.encode(ErrorEvent{ message: 'prover ranking failed' })
		return evt, 'error'
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	evt := json.encode(RankProversEvent{ success: true, data: result_str })
	return evt, 'rank_provers'
}

// Process an authenticate request and return the SSE event data JSON.
pub fn process_authenticate(body string) (string, string) {
	req := json.decode(AuthRequest, body) or {
		evt := json.encode(ErrorEvent{ message: 'invalid request: ${err}' })
		return evt, 'error'
	}

	result := C.echidna_llm_authenticate(req.token.str, req.token.len, req.max_calls, req.expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		evt := json.encode(AuthenticateEvent{ success: false, error: msg })
		return evt, 'authenticate'
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	evt := json.encode(AuthenticateEvent{
		success: true
		state: state_label(state)
		max_calls: req.max_calls
		expiry_ms: req.expiry_ms
	})
	return evt, 'authenticate'
}

// Process a status request and return the SSE event data JSON.
pub fn process_status() (string, string) {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	evt := json.encode(StatusEvent{
		state: state_label(state)
		session_valid: valid
	})
	return evt, 'status'
}

// Process a close request and return the SSE event data JSON.
pub fn process_close() (string, string) {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		evt := json.encode(CloseEvent{
			success: false
			state: state_label(state)
			error: 'cannot close — no active session'
		})
		return evt, 'close'
	}

	evt := json.encode(CloseEvent{
		success: true
		state: state_label(state)
	})
	return evt, 'close'
}

// ═══════════════════════════════════════════════════════════════════════
// Server configuration
// ═══════════════════════════════════════════════════════════════════════

// Configuration for the echidna-llm SSE server.
pub struct SseServerConfig {
pub:
	port              int    = 9811 // HTTP port to bind
	endpoint          string = 'http://localhost:7700' // BoJ endpoint
	heartbeat_seconds int    = 30 // heartbeat interval
}

// ═══════════════════════════════════════════════════════════════════════
// SSE HTTP response headers
// ═══════════════════════════════════════════════════════════════════════

// Format the HTTP response header for an SSE stream.
fn sse_stream_headers() string {
	return [
		'HTTP/1.1 200 OK',
		'Content-Type: text/event-stream',
		'Cache-Control: no-cache',
		'Connection: keep-alive',
		'Access-Control-Allow-Origin: *',
		'X-Accel-Buffering: no',
		'',
		'',
	].join('\r\n')
}

// Format a plain JSON HTTP response.
fn json_response(status int, body string) string {
	return [
		'HTTP/1.1 ${status} OK',
		'Content-Type: application/json',
		'Content-Length: ${body.len}',
		'Access-Control-Allow-Origin: *',
		'',
		body,
	].join('\r\n')
}

// ═══════════════════════════════════════════════════════════════════════
// Server lifecycle
// ═══════════════════════════════════════════════════════════════════════

// Start the echidna-llm SSE server. Binds to the configured port and
// handles both SSE stream connections and POST trigger requests.
pub fn start_server(config SseServerConfig) ! {
	C.echidna_llm_init(config.endpoint.str)

	mut registry := Registry.new()
	mut listener := net.listen_tcp(.ip, ':${config.port}') or {
		return error('failed to bind SSE server on port ${config.port}: ${err}')
	}
	defer { listener.close() or {} }

	for {
		mut conn := listener.accept() or { continue }
		handle_http_request(mut &registry, mut conn)
	}
}

// Parse an incoming HTTP request and route to SSE stream or POST handler.
fn handle_http_request(mut registry &Registry, mut conn net.TcpConn) {
	mut buf := []u8{len: 65536}
	n := conn.read(mut buf) or { return }
	if n == 0 {
		return
	}

	raw := buf[..n].bytestr()
	first_line := raw.split('\n')[0] or { return }
	parts := first_line.trim_space().split(' ')
	if parts.len < 2 {
		return
	}

	method := parts[0]
	path := parts[1]

	match method {
		'GET' {
			match path {
				'/echidna-llm/events' {
					// Send SSE headers and register client
					conn.write(sse_stream_headers().bytes()) or { return }
					client_id := registry.add(&conn)
					// Send initial status event
					data, evt_type := process_status()
					event_str := format_sse_event(evt_type, data, '0')
					conn.write(event_str.bytes()) or {
						registry.remove(client_id)
						return
					}
					// Connection stays open — client will receive broadcasts
				}
				'/echidna-llm/status' {
					data, _ := process_status()
					conn.write(json_response(200, data).bytes()) or {}
				}
				'/echidna-llm/health' {
					body := json.encode(HealthResponse{
						status: 'ok'
						adapter: 'echidna_llm_sse'
					})
					conn.write(json_response(200, body).bytes()) or {}
				}
				else {
					conn.write(json_response(404, '{"error":"not found"}').bytes()) or {}
				}
			}
		}
		'POST' {
			// Extract body (after blank line)
			body := if idx := raw.index('\r\n\r\n') {
				raw[idx + 4..]
			} else if idx2 := raw.index('\n\n') {
				raw[idx2 + 2..]
			} else {
				''
			}

			data, evt_type := match path {
				'/echidna-llm/suggest' { process_suggest_tactics(body) }
				'/echidna-llm/rank' { process_rank_provers(body) }
				'/echidna-llm/auth' { process_authenticate(body) }
				'/echidna-llm/close' { process_close() }
				else {
					json.encode(ErrorEvent{ message: 'unknown endpoint: ${path}' }), 'error'
				}
			}

			// Send JSON response to the POST caller
			conn.write(json_response(200, data).bytes()) or {}

			// Broadcast as SSE event to all subscribers
			registry.broadcast(evt_type, data)
		}
		else {
			conn.write(json_response(405, '{"error":"method not allowed"}').bytes()) or {}
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that SSE event formatting follows the W3C EventSource spec.
fn test_format_sse_event() {
	event := format_sse_event('suggest_tactics', '{"success":true}', '42')
	assert event.contains('id: 42')
	assert event.contains('event: suggest_tactics')
	assert event.contains('data: {"success":true}')
}

// Verify that heartbeat formatting produces a valid SSE comment.
fn test_format_heartbeat() {
	hb := format_heartbeat()
	assert hb.starts_with(': heartbeat')
	assert hb.ends_with('\n\n')
}

// Verify that multi-line data is correctly split across data: fields.
fn test_format_sse_multiline() {
	event := format_sse_event('test', 'line1\nline2\nline3', '1')
	assert event.contains('data: line1')
	assert event.contains('data: line2')
	assert event.contains('data: line3')
}

// Verify that process_status returns valid JSON.
fn test_process_status() {
	data, evt_type := process_status()
	assert evt_type == 'status'
	decoded := json.decode(StatusEvent, data) or {
		assert false, 'failed to decode status: ${err}'
		return
	}
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
}

// Verify that suggest_tactics without a session returns an error event.
fn test_process_suggest_no_session() {
	data, evt_type := process_suggest_tactics('{"goal":"forall n, n + 0 = n","prover_id":0}')
	assert evt_type == 'error'
	assert data.contains('session')
}

// Verify that rank_provers without a session returns an error event.
fn test_process_rank_no_session() {
	data, evt_type := process_rank_provers('{"goal":"P -> Q -> P"}')
	assert evt_type == 'error'
	assert data.contains('session')
}
