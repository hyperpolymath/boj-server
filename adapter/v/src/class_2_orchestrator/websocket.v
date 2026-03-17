// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Unified WebSocket Adapter
//
// A generic, high-performance WebSocket host that exposes cartridge
// capabilities over bidirectional JSON-RPC streams.
//
// Features:
//   - Unified Broker: Manages rooms (one per cartridge)
//   - JSON-RPC 2.0: Standardized message format
//   - Broadcast: Cartridges can push events to room members
//   - Lazy Rooms: Rooms are created only when a client joins
//
// Port: 7704 (default)

module main

import json
import net
import sync
import time

// ═══════════════════════════════════════════════════════════════════════
// WebSocket Protocol Types
// ═══════════════════════════════════════════════════════════════════════

struct WsRequest {
	jsonrpc string = "2.0"
	id      string
	method  string
	params  string // JSON-encoded parameters
}

struct WsResponse {
	jsonrpc string = "2.0"
	id      string
	result  string // JSON-encoded result
	error   WsError
}

struct WsError {
	code    int
	message string
}

struct WsNotification {
	jsonrpc string = "2.0"
	method  string
	params  string // JSON-encoded parameters
}

// ═══════════════════════════════════════════════════════════════════════
// Broker — Unified Client Management
// ═══════════════════════════════════════════════════════════════════════

struct WsClient {
	id   int
mut:
	conn &net.TcpConn
}

struct UnifiedBroker {
mut:
	mu      sync.Mutex
	rooms   map[string][]&WsClient // cartridge name -> list of clients
	next_id int
}

fn UnifiedBroker.new() UnifiedBroker {
	return UnifiedBroker{
		rooms: map[string][]&WsClient{}
		next_id: 1
	}
}

fn (mut b UnifiedBroker) join(cartridge string, conn &net.TcpConn) int {
	b.mu.@lock()
	defer { b.mu.unlock() }

	id := b.next_id
	b.next_id++

	client := &WsClient{
		id: id
		conn: conn
	}

	if cartridge in b.rooms {
		b.rooms[cartridge] << client
	} else {
		b.rooms[cartridge] = [client]
	}
	return id
}

fn (mut b UnifiedBroker) leave(cartridge string, client_id int) {
	b.mu.@lock()
	defer { b.mu.unlock() }

	if cartridge in b.rooms {
		b.rooms[cartridge] = b.rooms[cartridge].filter(it.id != client_id)
	}
}

fn (mut b UnifiedBroker) broadcast(cartridge string, method string, params string) {
	msg := json.encode(WsNotification{
		method: method
		params: params
	})

	b.mu.@lock()
	clients := if cartridge in b.rooms { b.rooms[cartridge].clone() } else { []&WsClient{} }
	b.mu.unlock()

	for c in clients {
		c.conn.write(msg.bytes()) or { continue }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Server Implementation
// ═══════════════════════════════════════════════════════════════════════

fn (mut app BojApp) start_websocket_server(port int) ! {
	mut broker := UnifiedBroker.new()
	mut listener := net.listen_tcp(.ip, ':${port}') or {
		return error('failed to bind WebSocket server on port ${port}: ${err}')
	}

	for {
		mut conn := listener.accept() or { continue }
		
		// Initial handshake: Client must send a JOIN frame
		// Expected: {"jsonrpc": "2.0", "method": "join", "params": {"cartridge": "nesy-mcp"}}
		mut buf := []u8{len: 1024}
		n := conn.read(mut buf) or { 
			conn.close() or {}
			continue 
		}
		
		join_req := json.decode(WsRequest, buf[..n].bytestr()) or {
			conn.write('{"error": "invalid join frame"}'.bytes()) or {}
			conn.close() or {}
			continue
		}

		if join_req.method != "join" {
			conn.write('{"error": "must join a cartridge room first"}'.bytes()) or {}
			conn.close() or {}
			continue
		}

		cartridge_params := json.decode(map[string]string, join_req.params) or {
			conn.write('{"error": "invalid join params"}'.bytes()) or {}
			conn.close() or {}
			continue
		}

		cname := cartridge_params["cartridge"] or { "" }
		if cname == "" {
			conn.write('{"error": "missing cartridge name"}'.bytes()) or {}
			conn.close() or {}
			continue
		}

		// Verify cartridge is mounted in BoJ catalogue
		mut mounted := false
		for c in app.cartridges {
			if c.name == cname {
				if C.boj_catalogue_is_mounted(c.index) == 1 {
					mounted = true
				}
				break
			}
		}

		if !mounted {
			conn.write('{"error": "cartridge not mounted"}'.bytes()) or {}
			conn.close() or {}
			continue
		}

		client_id := broker.join(cname, &conn)
		go handle_ws_client(mut app, mut &broker, mut conn, cname, client_id)
	}
}

fn handle_ws_client(mut app &BojApp, mut broker &UnifiedBroker, mut conn net.TcpConn, cname string, client_id int) {
	defer { 
		broker.leave(cname, client_id)
		conn.close() or {}
	}

	mut buf := []u8{len: 4096}
	for {
		n := conn.read(mut buf) or { break }
		if n == 0 { break }

		req := json.decode(WsRequest, buf[..n].bytestr()) or {
			conn.write('{"error": "invalid json-rpc"}'.bytes()) or {}
			continue
		}

		// Generic Dispatch: Use existing handle_cartridge_invoke logic
		// We re-use the REST invoke handler to process the tool call
		resp_body := handle_cartridge_invoke(app, cname, json.encode({
			"tool": req.method,
			"args": req.params
		}))

		ws_resp := WsResponse{
			id: req.id
			result: resp_body.body
		}
		
		conn.write(json.encode(ws_resp).bytes()) or { break }
	}
}
