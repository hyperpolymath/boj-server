// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// MCP SSE Transport — Server-Sent Events transport for the Model Context Protocol.
//
// Implements the MCP HTTP+SSE transport specification (2024-11-05):
//   - GET  /sse           → SSE event stream (server→client messages)
//   - POST /message       → JSON-RPC requests (client→server)
//   - GET  /health        → Health check endpoint
//
// This enables remote MCP clients (Glama, Claude Desktop, Cursor) to connect
// to BoJ without requiring stdio. The SSE stream carries server-initiated
// messages (notifications, responses), while POST /message receives requests.
//
// Protocol flow:
//   1. Client connects GET /sse → receives SSE stream
//   2. Server sends "endpoint" event with POST URL
//   3. Client sends JSON-RPC requests via POST /message
//   4. Server responds via the SSE stream with matching IDs
//
// Default port: 7703 (configurable via BOJ_SSE_PORT env var)

module main

import json
import net
import net.http
import os
import time
import sync

// ═══════════════════════════════════════════════════════════════════════
// SSE Session Management
// ═══════════════════════════════════════════════════════════════════════

/// A connected SSE client session. Each GET /sse connection creates one.
/// Messages are queued and flushed to the client's event stream.
@[heap]
struct SseSession {
	id         string         // Unique session ID (UUID-like)
	created_at i64            // Unix timestamp
mut:
	outbox     []string       // Queued SSE events waiting to be sent
	alive      bool           // False when client disconnects
	last_ping  i64            // Last keepalive timestamp
}

/// Global SSE session registry. Thread-safe via mutex.
struct SseRegistry {
mut:
	sessions []&SseSession
	mu       sync.Mutex
}

/// Create a new empty registry.
fn SseRegistry.new() SseRegistry {
	return SseRegistry{
		sessions: []&SseSession{}
	}
}

/// Register a new SSE session. Returns session ID.
fn (mut r SseRegistry) add_session() string {
	r.mu.@lock()
	defer { r.mu.unlock() }

	session_id := generate_session_id()
	session := &SseSession{
		id: session_id
		created_at: time.now().unix()
		outbox: []string{}
		alive: true
		last_ping: time.now().unix()
	}
	r.sessions << session
	return session_id
}

/// Find a session by ID.
fn (mut r SseRegistry) get_session(id string) ?&SseSession {
	r.mu.@lock()
	defer { r.mu.unlock() }

	for s in r.sessions {
		if s.id == id {
			return s
		}
	}
	return none
}

/// Queue a message for a specific session.
fn (mut r SseRegistry) send_to(session_id string, event_type string, data string) {
	r.mu.@lock()
	defer { r.mu.unlock() }

	for mut s in r.sessions {
		if s.id == session_id && s.alive {
			// Format as SSE: event: <type>\ndata: <json>\n\n
			s.outbox << 'event: ${event_type}\ndata: ${data}\n\n'
			break
		}
	}
}

/// Drain queued messages for a session. Returns empty array if none pending.
fn (mut r SseRegistry) drain(session_id string) []string {
	r.mu.@lock()
	defer { r.mu.unlock() }

	for mut s in r.sessions {
		if s.id == session_id {
			msgs := s.outbox.clone()
			s.outbox.clear()
			return msgs
		}
	}
	return []string{}
}

/// Remove dead sessions (disconnected or timed out).
fn (mut r SseRegistry) cleanup() {
	r.mu.@lock()
	defer { r.mu.unlock() }

	now := time.now().unix()
	r.sessions = r.sessions.filter(it.alive && (now - it.last_ping) < 300)
}

/// Mark a session as dead.
fn (mut r SseRegistry) disconnect(session_id string) {
	r.mu.@lock()
	defer { r.mu.unlock() }

	for mut s in r.sessions {
		if s.id == session_id {
			s.alive = false
			break
		}
	}
}

/// Generate a simple session ID (timestamp + counter).
fn generate_session_id() string {
	ts := time.now().unix()
	return 'sse-${ts}-${time.now().unix_nano() % 100000}'
}

// ═══════════════════════════════════════════════════════════════════════
// SSE HTTP Handler
// ═══════════════════════════════════════════════════════════════════════

/// HTTP handler for the SSE transport endpoints.
struct SseHandler {
	app      &BojApp
mut:
	registry SseRegistry
}

fn (mut h SseHandler) handle(req http.Request) http.Response {
	path := req.url.trim_right('/')

	// CORS headers for browser-based MCP clients
	cors_headers := {
		'Access-Control-Allow-Origin':  '*'
		'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
		'Access-Control-Allow-Headers': 'Content-Type'
	}

	// Preflight
	if req.method == .options {
		mut resp := http.Response{
			status_msg: 'OK'
		}
		for k, v in cors_headers {
			resp.header.add_custom(k, v) or {}
		}
		return resp
	}

	return match path {
		'/sse' {
			h.handle_sse_connect(req, cors_headers)
		}
		'/message' {
			h.handle_message(req, cors_headers)
		}
		'/health' {
			h.handle_health(cors_headers)
		}
		else {
			mut resp := http.new_response(
				status: .not_found
				body: '{"error":"Not found. Endpoints: GET /sse, POST /message, GET /health"}'
			)
			resp.header.set(.content_type, 'application/json')
			resp
		}
	}
}

/// GET /sse — Establish SSE event stream.
/// The initial event sends the session ID and message endpoint URL.
fn (mut h SseHandler) handle_sse_connect(req http.Request, cors_headers map[string]string) http.Response {
	session_id := h.registry.add_session()

	// Determine the base URL for the POST endpoint
	host := req.header.get(.host) or { 'localhost:7703' }
	post_url := 'http://${host}/message?sessionId=${session_id}'

	// Build the initial SSE response with endpoint event
	mut body_parts := []string{}
	body_parts << 'event: endpoint\ndata: ${post_url}\n\n'

	// Send a keepalive comment
	body_parts << ': keepalive\n\n'

	// Drain any queued messages (there won't be any yet, but future-proof)
	msgs := h.registry.drain(session_id)
	for msg in msgs {
		body_parts << msg
	}

	mut resp := http.new_response(
		status: .ok
		body: body_parts.join('')
	)
	resp.header.set(.content_type, 'text/event-stream')
	resp.header.add_custom('Cache-Control', 'no-cache') or {}
	resp.header.add_custom('Connection', 'keep-alive') or {}
	resp.header.add_custom('X-Session-Id', session_id) or {}
	for k, v in cors_headers {
		resp.header.add_custom(k, v) or {}
	}
	return resp
}

/// POST /message — Receive JSON-RPC request from client.
/// Processes the request and queues the response on the session's SSE stream.
/// Also returns the response directly in the HTTP response body.
fn (mut h SseHandler) handle_message(req http.Request, cors_headers map[string]string) http.Response {
	if req.method != .post {
		mut resp := http.new_response(
			status: .method_not_allowed
			body: '{"error":"POST required"}'
		)
		resp.header.set(.content_type, 'application/json')
		return resp
	}

	// Extract session ID from query parameter
	session_id := extract_query_param(req.url, 'sessionId') or {
		mut resp := http.new_response(
			status: .bad_request
			body: '{"error":"Missing sessionId query parameter"}'
		)
		resp.header.set(.content_type, 'application/json')
		return resp
	}

	// Parse JSON-RPC request
	body := req.data
	mcp_req := json.decode(McpRequest, body) or {
		result := mcp_error(0, -32700, 'parse error')
		h.registry.send_to(session_id, 'message', result)
		mut resp := http.new_response(
			status: .ok
			body: result
		)
		resp.header.set(.content_type, 'application/json')
		return resp
	}

	app_ref := h.app

	// Dispatch by method (same logic as stdio MCP)
	response := match mcp_req.method {
		'initialize' {
			mcp_response(mcp_req.id, '{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"boj-server","version":"0.3.0"}}')
		}
		'notifications/initialized' {
			''
		}
		'tools/list' {
			tools := mcp_tools_list(app_ref)
			mcp_response(mcp_req.id, '{"tools":${tools}}')
		}
		'tools/call' {
			tool_name := mcp_req.params['name'] or { '' }
			tool_args := mcp_req.params['arguments'] or { '{}' }
			result := mcp_handle_tool_call(app_ref, tool_name, tool_args)
			mcp_response(mcp_req.id, result)
		}
		'ping' {
			mcp_response(mcp_req.id, '{}')
		}
		else {
			mcp_error(mcp_req.id, -32601, 'method not found: ${mcp_req.method}')
		}
	}

	// Queue the response on the SSE stream too
	if response.len > 0 {
		h.registry.send_to(session_id, 'message', response)
	}

	// Return response directly (dual delivery: HTTP response + SSE)
	mut resp := http.new_response(
		status: .ok
		body: if response.len > 0 { response } else { '{}' }
	)
	resp.header.set(.content_type, 'application/json')
	for k, v in cors_headers {
		resp.header.add_custom(k, v) or {}
	}
	return resp
}

/// GET /health — Health check for the SSE transport.
fn (mut h SseHandler) handle_health(cors_headers map[string]string) http.Response {
	h.registry.cleanup()

	active := h.registry.sessions.filter(it.alive).len
	health := json.encode({
		'status':    'ok'
		'transport': 'sse'
		'sessions':  '${active}'
		'server':    'boj-server'
		'version':   '0.3.0'
	})

	mut resp := http.new_response(
		status: .ok
		body: health
	)
	resp.header.set(.content_type, 'application/json')
	for k, v in cors_headers {
		resp.header.add_custom(k, v) or {}
	}
	return resp
}

/// Extract a query parameter from a URL string.
fn extract_query_param(url string, key string) ?string {
	query_start := url.index('?') or { return none }
	query := url[query_start + 1..]
	for pair in query.split('&') {
		parts := pair.split('=')
		if parts.len == 2 && parts[0] == key {
			return parts[1]
		}
	}
	return none
}

// ═══════════════════════════════════════════════════════════════════════
// SSE Server Startup (called from main)
// ═══════════════════════════════════════════════════════════════════════

/// Start the MCP SSE transport server on the configured port.
/// Called from main() alongside REST/gRPC/GraphQL servers.
fn start_sse_transport(app &BojApp) {
	sse_port := os.getenv_opt('BOJ_SSE_PORT') or { '7703' }

	sse_listener := net.listen_tcp(.ip, '0.0.0.0:${sse_port}') or {
		eprintln('WARNING: cannot bind SSE on :${sse_port}: ${err} (SSE transport disabled)')
		return
	}

	println('Starting MCP/SSE on :${sse_port}')

	mut sse_handler := SseHandler{
		app: app
		registry: SseRegistry.new()
	}

	mut sse_srv := &http.Server{
		listener: sse_listener
		handler: sse_handler
		show_startup_message: false
	}

	spawn sse_srv.listen_and_serve()
}
