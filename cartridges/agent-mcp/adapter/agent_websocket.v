// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Agent-MCP Cartridge — WebSocket adapter layer.
//
// Exposes the OODA loop FSM over a WebSocket server. Each new client
// connection automatically receives a fresh OODA session. Clients send
// slash-style text commands (/advance, /transition, /halt, /status,
// /validate, /tool, /safety, /health) and receive JSON responses.
// State changes are broadcast to all clients in the "ooda" room so that
// dashboards and monitoring tools stay synchronised in real-time.

module agent_websocket

import json
import net.websocket

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against agent_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.agent_new_session() int
fn C.agent_end_session(idx int) int
fn C.agent_transition(idx int, to int) int
fn C.agent_state(idx int) int
fn C.agent_loop_count(idx int) int
fn C.agent_validate_ooda(from int, to int) int
fn C.agent_next_state(current int) int
fn C.agent_reset()
// Protocol FFI (v0.2.0 — from proven-agentic)
fn C.agent_tool_has_side_effects(tc int) int
fn C.agent_tool_requires_safety(tc int) int
fn C.agent_safety_allows_exec(sc int) int
fn C.agent_safety_needs_human(sc int) int
fn C.agent_coordination_is_multi(c int) int
fn C.agent_memory_is_persistent(m int) int

// ═══════════════════════════════════════════════════════════════════════
// Label helpers — convert integer encodings to human-readable strings.
// Mirrors the canonical labels in agent_adapter.v so each adapter is
// self-contained.
// ═══════════════════════════════════════════════════════════════════════

// state_label converts an AgentState integer (1–5) to its OODA name.
fn state_label(s int) string {
	return match s {
		1 { 'observe' }
		2 { 'orient' }
		3 { 'decide' }
		4 { 'act' }
		5 { 'halted' }
		else { 'unknown' }
	}
}

// state_from_name converts a state name back to its integer encoding.
// Returns an error for unrecognised names.
fn state_from_name(name string) !int {
	return match name {
		'observe' { 1 }
		'orient' { 2 }
		'decide' { 3 }
		'act' { 4 }
		'halted' { 5 }
		else { return error('unknown state: ${name}') }
	}
}

// tool_call_label converts a ToolCall integer (0–5) to its name.
fn tool_call_label(t int) string {
	return match t {
		0 { 'Execute' }
		1 { 'Query' }
		2 { 'Transform' }
		3 { 'Communicate' }
		4 { 'Delegate' }
		5 { 'Escalate' }
		else { 'Unknown' }
	}
}

// safety_check_label converts a SafetyCheck integer (0–5) to its name.
fn safety_check_label(s int) string {
	return match s {
		0 { 'Approved' }
		1 { 'Denied' }
		2 { 'Escalated' }
		3 { 'Timeout' }
		4 { 'Sandboxed' }
		5 { 'HumanRequired' }
		else { 'Unknown' }
	}
}

// tool_call_from_name converts a tool call name to its integer encoding.
fn tool_call_from_name(kind string) !int {
	return match kind.to_lower() {
		'execute' { 0 }
		'query' { 1 }
		'transform' { 2 }
		'communicate' { 3 }
		'delegate' { 4 }
		'escalate' { 5 }
		else { return error('unknown tool call: ${kind}') }
	}
}

// safety_check_from_name converts a safety outcome name to its integer encoding.
fn safety_check_from_name(outcome string) !int {
	return match outcome.to_lower() {
		'approved' { 0 }
		'denied' { 1 }
		'escalated' { 2 }
		'timeout' { 3 }
		'sandboxed' { 4 }
		'humanrequired', 'human_required' { 5 }
		else { return error('unknown safety check: ${outcome}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Response types — JSON-serialisable structs sent back to WS clients.
// ═══════════════════════════════════════════════════════════════════════

// WsResponse wraps every outbound message with a type tag and either
// a data payload or an error string.
struct WsResponse {
	msg_type string        @[json: 'type']
	data     string        @[json: 'data'; omitempty]
	error    string        @[json: 'error'; omitempty]
}

// SessionPayload holds the state snapshot for a session.
struct SessionPayload {
	session_id int
	state      string
	loop_count int
}

// TransitionPayload reports the result of a state transition.
struct TransitionPayload {
	session_id int
	from       string
	to         string
	success    bool
	next_state string
}

// ValidationPayload reports whether a proposed transition is valid.
struct ValidationPayload {
	from    string
	to      string
	allowed bool
}

// ToolInfoPayload reports tool-call safety metadata.
struct ToolInfoPayload {
	kind                  string
	has_side_effects      bool
	requires_safety_check bool
}

// SafetyInfoPayload reports safety-check metadata.
struct SafetyInfoPayload {
	outcome          string
	allows_execution bool
	needs_human      bool
}

// HealthPayload reports server health status.
struct HealthPayload {
	status   string
	protocol string
}

// ═══════════════════════════════════════════════════════════════════════
// Client-session map — tracks which WS client owns which OODA session.
// ═══════════════════════════════════════════════════════════════════════

// ClientSession binds a websocket client pointer to an OODA session id.
struct ClientSession {
mut:
	session_id int
}

// ═══════════════════════════════════════════════════════════════════════
// WebSocket Server
// ═══════════════════════════════════════════════════════════════════════

// WsServer holds the server instance and the mapping from client to
// OODA session, plus a list of all connected clients for broadcasting.
struct WsServer {
mut:
	sessions map[string]ClientSession  // keyed by client address string
	clients  []&websocket.ServerClient // all connected clients for broadcast
}

// broadcast_state sends a state-change notification to all connected
// clients in the "ooda" room (i.e. all clients).
fn (mut srv WsServer) broadcast_state(session_id int, from_state string, to_state string) {
	payload := json.encode(TransitionPayload{
		session_id: session_id
		from: from_state
		to: to_state
		success: true
		next_state: state_label(C.agent_next_state(state_from_name(to_state) or { 0 }))
	})
	msg := json.encode(WsResponse{
		msg_type: 'state_change'
		data: payload
	})
	for mut client in srv.clients {
		client.write_string(msg) or { continue }
	}
}

// handle_message parses a slash command from the client and dispatches
// it to the appropriate FFI call.  Returns the JSON response string.
fn (mut srv WsServer) handle_message(client_addr string, raw string) string {
	parts := raw.trim_space().split(' ')
	if parts.len == 0 {
		return json.encode(WsResponse{ msg_type: 'error', error: 'empty command' })
	}
	cmd := parts[0]

	// Look up the session for this client.
	sess := srv.sessions[client_addr] or {
		return json.encode(WsResponse{ msg_type: 'error', error: 'no session for client' })
	}

	match cmd {
		'/advance' {
			// Advance the session to the next OODA step.
			current := C.agent_state(sess.session_id)
			if current < 0 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'session not found' })
			}
			next := C.agent_next_state(current)
			result := C.agent_transition(sess.session_id, next)
			if result < 0 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'transition failed' })
			}
			from_label := state_label(current)
			to_label := state_label(next)
			srv.broadcast_state(sess.session_id, from_label, to_label)
			payload := json.encode(TransitionPayload{
				session_id: sess.session_id
				from: from_label
				to: to_label
				success: true
				next_state: state_label(C.agent_next_state(next))
			})
			return json.encode(WsResponse{ msg_type: 'advance', data: payload })
		}
		'/transition' {
			// Transition to a named state: /transition orient
			if parts.len < 2 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'usage: /transition <state>' })
			}
			target := state_from_name(parts[1]) or {
				return json.encode(WsResponse{ msg_type: 'error', error: err.msg() })
			}
			current := C.agent_state(sess.session_id)
			if current < 0 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'session not found' })
			}
			result := C.agent_transition(sess.session_id, target)
			if result < 0 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'invalid transition' })
			}
			from_label := state_label(current)
			to_label := parts[1]
			srv.broadcast_state(sess.session_id, from_label, to_label)
			payload := json.encode(TransitionPayload{
				session_id: sess.session_id
				from: from_label
				to: to_label
				success: true
				next_state: state_label(C.agent_next_state(target))
			})
			return json.encode(WsResponse{ msg_type: 'transition', data: payload })
		}
		'/halt' {
			// Halt the session immediately.
			current := C.agent_state(sess.session_id)
			result := C.agent_transition(sess.session_id, 5) // 5 = halted
			if result < 0 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'halt failed' })
			}
			srv.broadcast_state(sess.session_id, state_label(current), 'halted')
			payload := json.encode(SessionPayload{
				session_id: sess.session_id
				state: 'halted'
				loop_count: C.agent_loop_count(sess.session_id)
			})
			return json.encode(WsResponse{ msg_type: 'halt', data: payload })
		}
		'/status' {
			// Return current session status.
			s := C.agent_state(sess.session_id)
			if s < 0 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'session not found' })
			}
			payload := json.encode(SessionPayload{
				session_id: sess.session_id
				state: state_label(s)
				loop_count: C.agent_loop_count(sess.session_id)
			})
			return json.encode(WsResponse{ msg_type: 'status', data: payload })
		}
		'/validate' {
			// Validate a proposed transition: /validate observe orient
			if parts.len < 3 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'usage: /validate <from> <to>' })
			}
			from_int := state_from_name(parts[1]) or {
				return json.encode(WsResponse{ msg_type: 'error', error: err.msg() })
			}
			to_int := state_from_name(parts[2]) or {
				return json.encode(WsResponse{ msg_type: 'error', error: err.msg() })
			}
			allowed := C.agent_validate_ooda(from_int, to_int) == 1
			payload := json.encode(ValidationPayload{
				from: parts[1]
				to: parts[2]
				allowed: allowed
			})
			return json.encode(WsResponse{ msg_type: 'validate', data: payload })
		}
		'/tool' {
			// Query tool-call metadata: /tool execute
			if parts.len < 2 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'usage: /tool <kind>' })
			}
			tc := tool_call_from_name(parts[1]) or {
				return json.encode(WsResponse{ msg_type: 'error', error: err.msg() })
			}
			payload := json.encode(ToolInfoPayload{
				kind: tool_call_label(tc)
				has_side_effects: C.agent_tool_has_side_effects(tc) == 1
				requires_safety_check: C.agent_tool_requires_safety(tc) == 1
			})
			return json.encode(WsResponse{ msg_type: 'tool', data: payload })
		}
		'/safety' {
			// Query safety-check metadata: /safety approved
			if parts.len < 2 {
				return json.encode(WsResponse{ msg_type: 'error', error: 'usage: /safety <outcome>' })
			}
			sc := safety_check_from_name(parts[1]) or {
				return json.encode(WsResponse{ msg_type: 'error', error: err.msg() })
			}
			payload := json.encode(SafetyInfoPayload{
				outcome: safety_check_label(sc)
				allows_execution: C.agent_safety_allows_exec(sc) == 1
				needs_human: C.agent_safety_needs_human(sc) == 1
			})
			return json.encode(WsResponse{ msg_type: 'safety', data: payload })
		}
		'/health' {
			// Simple liveness check.
			payload := json.encode(HealthPayload{
				status: 'ok'
				protocol: 'websocket'
			})
			return json.encode(WsResponse{ msg_type: 'health', data: payload })
		}
		else {
			return json.encode(WsResponse{
				msg_type: 'error'
				error: 'unknown command: ${cmd} — try /advance /transition /halt /status /validate /tool /safety /health'
			})
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Public API — start the WebSocket server
// ═══════════════════════════════════════════════════════════════════════

// start_ws_server creates a WebSocket server on the given port.
// Each connecting client automatically gets a new OODA session.
// The server listens for slash-commands and responds with JSON.
pub fn start_ws_server(port int) ! {
	mut srv := &WsServer{
		sessions: map[string]ClientSession{}
		clients: []&websocket.ServerClient{}
	}

	mut ws_server := websocket.Server.new(websocket.ServerOpt{
		port: port
	})

	// On new client connection: allocate a fresh OODA session.
	ws_server.on_connect(fn [mut srv] (mut client websocket.ServerClient) !bool {
		idx := C.agent_new_session()
		if idx < 0 {
			client.write_string(json.encode(WsResponse{
				msg_type: 'error'
				error: 'no session slots available'
			})) or {}
			return false
		}
		addr := client.client.addr.str()
		srv.sessions[addr] = ClientSession{ session_id: idx }
		srv.clients << &client
		// Send the initial session payload to the newly connected client.
		welcome := json.encode(WsResponse{
			msg_type: 'session_created'
			data: json.encode(SessionPayload{
				session_id: idx
				state: 'observe'
				loop_count: 0
			})
		})
		client.write_string(welcome) or {}
		return true
	})

	// On message: dispatch the slash command.
	ws_server.on_message(fn [mut srv] (mut client websocket.ServerClient, msg &websocket.Message) ! {
		if msg.opcode == .text_frame {
			addr := client.client.addr.str()
			response := srv.handle_message(addr, msg.payload.bytestr())
			client.write_string(response) or {}
		}
	})

	// On close: end the OODA session and clean up.
	ws_server.on_close(fn [mut srv] (mut client websocket.ServerClient, code int, reason string) ! {
		addr := client.client.addr.str()
		if sess := srv.sessions[addr] {
			C.agent_end_session(sess.session_id)
			srv.sessions.delete(addr)
		}
	})

	ws_server.listen() or { return error('websocket server failed: ${err}') }
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// test_handle_health verifies that the /health command returns the
// expected JSON structure without requiring an active OODA session.
fn test_handle_health() {
	mut srv := WsServer{
		sessions: map[string]ClientSession{}
		clients: []&websocket.ServerClient{}
	}
	// Register a fake session so the handler does not bail on lookup.
	srv.sessions['test'] = ClientSession{ session_id: 0 }
	response := srv.handle_message('test', '/health')
	decoded := json.decode(WsResponse, response) or {
		assert false, 'failed to decode response'
		return
	}
	assert decoded.msg_type == 'health'
	assert decoded.error == ''
}
