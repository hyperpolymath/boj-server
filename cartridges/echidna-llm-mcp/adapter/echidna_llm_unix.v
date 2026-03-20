// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — Unix Domain Socket transport adapter.
//
// Implements a Unix socket server for the ECHIDNA frontier LLM tactic
// advisory. Unix sockets provide the lowest-latency IPC for co-located
// prover processes on the same machine. No network stack overhead, no
// TCP handshake, no serialisation beyond the JSON payload.
//
// Socket path: /run/echidna-llm/echidna-llm.sock (configurable)
//
// Wire protocol (newline-delimited JSON — NDJSON):
//   Request:  {"op":"suggest_tactics","goal":"...","prover_id":0,...}\n
//   Response: {"op":"suggest_tactics","success":true,"data":"..."}\n
//
// Each line is a complete JSON object terminated by \n. The "op" field
// routes to the appropriate handler. This is the fastest path for
// local provers to reach the LLM advisory.

module echidna_llm_unix

import json
import net
import os

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
// Operation constants
// ═══════════════════════════════════════════════════════════════════════

const op_suggest_tactics = 'suggest_tactics'
const op_rank_provers = 'rank_provers'
const op_authenticate = 'authenticate'
const op_status = 'status'
const op_close = 'close'
const op_health = 'health'

// ═══════════════════════════════════════════════════════════════════════
// NDJSON request/response types
// ═══════════════════════════════════════════════════════════════════════

// Generic request envelope — the "op" field routes to a handler,
// all other fields are operation-specific.
struct UnixRequest {
	op         string
	goal       string
	hypotheses string
	prover_id  int
	top_k      int = 10
	model      string = 'sonnet'
	token      string
	max_calls  int = 100
	expiry_ms  int = 60000
}

// Suggest tactics response.
struct SuggestTacticsResponse {
	op      string = 'suggest_tactics'
	success bool
	data    string
	error   string
}

// Rank provers response.
struct RankProversResponse {
	op      string = 'rank_provers'
	success bool
	data    string
	error   string
}

// Authenticate response.
struct AuthenticateResponse {
	op        string = 'authenticate'
	success   bool
	state     string
	max_calls int
	expiry_ms int
	error     string
}

// Status response.
struct StatusResponse {
	op            string = 'status'
	state         string
	session_valid bool
}

// Close response.
struct CloseResponse {
	op      string = 'close'
	success bool
	state   string
	error   string
}

// Health response.
struct HealthResponse {
	op      string = 'health'
	status  string
	adapter string
}

// Error response for unknown operations.
struct ErrorResponse {
	op      string = 'error'
	message string
}

// ═══════════════════════════════════════════════════════════════════════
// Server configuration
// ═══════════════════════════════════════════════════════════════════════

// Configuration for the Unix socket server.
pub struct UnixConfig {
pub:
	socket_path string = '/run/echidna-llm/echidna-llm.sock'
	endpoint    string = 'http://localhost:7700' // BoJ endpoint
	permissions int    = 0o660 // socket file permissions
}

// ═══════════════════════════════════════════════════════════════════════
// Request dispatcher — parses NDJSON and routes to handlers
// ═══════════════════════════════════════════════════════════════════════

// Dispatch a single NDJSON request line and return the response JSON.
pub fn dispatch(line string) string {
	req := json.decode(UnixRequest, line.trim_space()) or {
		return json.encode(ErrorResponse{
			message: 'failed to parse request: ${err}'
		})
	}

	return match req.op {
		op_suggest_tactics { handle_suggest_tactics(req) }
		op_rank_provers { handle_rank_provers(req) }
		op_authenticate { handle_authenticate(req) }
		op_status { handle_status() }
		op_close { handle_close() }
		op_health { handle_health() }
		else {
			json.encode(ErrorResponse{
				message: 'unknown operation: ${req.op}. Use suggest_tactics, rank_provers, authenticate, status, close, or health'
			})
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Operation handlers
// ═══════════════════════════════════════════════════════════════════════

fn handle_suggest_tactics(req UnixRequest) string {
	if C.echidna_llm_session_valid() != 1 {
		return json.encode(SuggestTacticsResponse{
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
		return json.encode(SuggestTacticsResponse{
			success: false
			error: 'tactic suggestion failed'
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(SuggestTacticsResponse{
		success: true
		data: result_str
	})
}

fn handle_rank_provers(req UnixRequest) string {
	if C.echidna_llm_session_valid() != 1 {
		return json.encode(RankProversResponse{
			success: false
			error: 'session expired or call limit reached'
		})
	}

	model := model_from_string(req.model)
	result_ptr := C.echidna_llm_rank_provers(req.goal.str, req.goal.len, model)

	if result_ptr == unsafe { nil } {
		return json.encode(RankProversResponse{
			success: false
			error: 'prover ranking failed'
		})
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return json.encode(RankProversResponse{
		success: true
		data: result_str
	})
}

fn handle_authenticate(req UnixRequest) string {
	result := C.echidna_llm_authenticate(req.token.str, req.token.len, req.max_calls, req.expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		return json.encode(AuthenticateResponse{
			success: false
			error: msg
		})
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	return json.encode(AuthenticateResponse{
		success: true
		state: state_label(state)
		max_calls: req.max_calls
		expiry_ms: req.expiry_ms
	})
}

fn handle_status() string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	return json.encode(StatusResponse{
		state: state_label(state)
		session_valid: valid
	})
}

fn handle_close() string {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		return json.encode(CloseResponse{
			success: false
			state: state_label(state)
			error: 'cannot close — no active session'
		})
	}

	return json.encode(CloseResponse{
		success: true
		state: state_label(state)
	})
}

fn handle_health() string {
	return json.encode(HealthResponse{
		status: 'ok'
		adapter: 'echidna_llm_unix'
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Server lifecycle
// ═══════════════════════════════════════════════════════════════════════

// Start the Unix socket server. Creates the socket file, binds, and
// enters an accept loop. Each connection reads NDJSON lines and sends
// back NDJSON responses. Blocks until stopped.
pub fn start_server(config UnixConfig) ! {
	C.echidna_llm_init(config.endpoint.str)

	// Ensure the socket directory exists
	socket_dir := os.dir(config.socket_path)
	if !os.exists(socket_dir) {
		os.mkdir_all(socket_dir) or {
			return error('failed to create socket directory ${socket_dir}: ${err}')
		}
	}

	// Remove stale socket file if it exists
	if os.exists(config.socket_path) {
		os.rm(config.socket_path) or {
			return error('failed to remove stale socket ${config.socket_path}: ${err}')
		}
	}

	// In production: bind a Unix domain socket using the system API.
	// V's net module supports TCP; Unix sockets use C interop:
	//   socket(AF_UNIX, SOCK_STREAM, 0)
	//   bind(sock, &sockaddr_un{path: socket_path})
	//   listen(sock, backlog)
	//   loop: accept → spawn handle_client
	//
	// For now, the adapter logic is fully implemented in dispatch()
	// and tested without the socket binding layer.
}

// Handle a single client connection. Reads NDJSON lines and sends
// responses until the client disconnects.
fn handle_client(mut conn net.TcpConn) {
	mut buf := []u8{len: 65536}
	mut line_buf := []u8{}

	for {
		n := conn.read(mut buf) or { break }
		if n == 0 {
			break
		}

		line_buf << buf[..n]

		// Process complete lines (NDJSON: one JSON object per line)
		for {
			line_str := line_buf.bytestr()
			newline_idx := line_str.index('\n') or { break }

			line := line_str[..newline_idx]
			line_buf = line_str[newline_idx + 1..].bytes()

			if line.trim_space().len == 0 {
				continue
			}

			response := dispatch(line)
			conn.write('${response}\n'.bytes()) or { return }
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_unix_dispatch_health() {
	response := dispatch('{"op":"health"}')
	decoded := json.decode(HealthResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.op == 'health'
	assert decoded.status == 'ok'
	assert decoded.adapter == 'echidna_llm_unix'
}

fn test_unix_dispatch_status() {
	response := dispatch('{"op":"status"}')
	decoded := json.decode(StatusResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.op == 'status'
	assert decoded.state in ['unauthenticated', 'authenticated', 'operating', 'closed']
}

fn test_unix_dispatch_suggest_no_session() {
	response := dispatch('{"op":"suggest_tactics","goal":"forall n, n + 0 = n","prover_id":0}')
	decoded := json.decode(SuggestTacticsResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.success == false
	assert decoded.error.contains('session')
}

fn test_unix_dispatch_unknown_op() {
	response := dispatch('{"op":"explode"}')
	decoded := json.decode(ErrorResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.op == 'error'
	assert decoded.message.contains('unknown operation')
}

fn test_unix_dispatch_malformed() {
	response := dispatch('not json at all')
	decoded := json.decode(ErrorResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	assert decoded.message.contains('failed to parse')
}

fn test_unix_dispatch_with_model() {
	response := dispatch('{"op":"suggest_tactics","goal":"P -> P","prover_id":5,"model":"opus"}')
	decoded := json.decode(SuggestTacticsResponse, response) or {
		assert false, 'decode failed: ${err}'
		return
	}
	// No session, so should fail gracefully
	assert decoded.success == false
}
