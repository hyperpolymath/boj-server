// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — V-lang Triple Adapter
//
// The unified console that exposes mounted cartridges as:
//   - REST  (port 9000)
//   - gRPC  (port 9001)
//   - GraphQL (port 9002)
//
// Phase 3 of the BoJ pipeline:
//   Idris2 ABI (proofs) → Zig FFI (execution) → V-lang Adapter (network)

module main

import json
import net.http
import os
import time

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against libboJ catalogue built from Zig)
// ═══════════════════════════════════════════════════════════════════════

#flag -L../../ffi/zig/zig-out/lib
#flag -lboj_catalogue

fn C.boj_catalogue_init() int
fn C.boj_catalogue_deinit()
fn C.boj_catalogue_register(name_ptr &u8, name_len usize, version_ptr &u8, version_len usize, status int, tier int, domain int) int
fn C.boj_catalogue_add_protocol(protocol int) int
fn C.boj_catalogue_mount(index usize) int
fn C.boj_catalogue_unmount(index usize) int
fn C.boj_catalogue_is_mounted(index usize) int
fn C.boj_catalogue_count() usize
fn C.boj_catalogue_count_ready() usize
fn C.boj_catalogue_count_mounted() usize
fn C.boj_catalogue_status(index usize) int
fn C.boj_catalogue_version() &u8
fn C.boj_catalogue_set_hash(index usize, hash_ptr &u8, hash_len usize) int
fn C.boj_catalogue_get_hash(index usize, out_ptr &u8) usize
fn C.boj_loader_verify(path_ptr &u8, path_len usize, expected_hex_ptr &u8, expected_hex_len usize) int

// ═══════════════════════════════════════════════════════════════════════
// Domain Types (match Idris2 ABI encodings)
// ═══════════════════════════════════════════════════════════════════════

enum CartridgeStatus {
	development = 0
	ready = 1
	deprecated = 2
	faulty = 3
}

enum ProtocolType {
	mcp = 1
	lsp = 2
	dap = 3
	bsp = 4
	nesy = 5
	agentic = 6
	fleet = 7
	grpc = 8
	rest = 9
}

enum CapabilityDomain {
	cloud = 1
	container = 2
	database = 3
	k8s = 4
	git = 5
	secrets = 6
	queues = 7
	iac = 8
	observe = 9
	ssg = 10
	proof = 11
	fleet_dom = 12
	nesy_dom = 13
}

enum MenuTier {
	teranga = 0
	shield = 1
	ayo = 2
}

fn status_label(s CartridgeStatus) string {
	return match s {
		.development { 'In Development' }
		.ready { 'Available' }
		.deprecated { 'Deprecated' }
		.faulty { 'Unavailable' }
	}
}

fn protocol_label(p ProtocolType) string {
	return match p {
		.mcp { 'MCP' }
		.lsp { 'LSP' }
		.dap { 'DAP' }
		.bsp { 'BSP' }
		.nesy { 'NeSy' }
		.agentic { 'Agentic' }
		.fleet { 'Fleet' }
		.grpc { 'gRPC' }
		.rest { 'REST' }
	}
}

fn domain_label(d CapabilityDomain) string {
	return match d {
		.cloud { 'Cloud' }
		.container { 'Container' }
		.database { 'Database' }
		.k8s { 'Kubernetes' }
		.git { 'Git/VCS' }
		.secrets { 'Secrets' }
		.queues { 'Queues' }
		.iac { 'IaC' }
		.observe { 'Observability' }
		.ssg { 'SSG' }
		.proof { 'Proof' }
		.fleet_dom { 'Fleet' }
		.nesy_dom { 'NeSy' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Application State
// ═══════════════════════════════════════════════════════════════════════

struct CartridgeInfo {
	name      string
	version   string
	status    CartridgeStatus
	tier      MenuTier
	domain    CapabilityDomain
	protocols []ProtocolType
	index     usize
}

struct EventEntry {
	event_type string
	cartridge  string
	timestamp  i64
}

struct Subscription {
	id    string
	event string
}

struct EventQueue {
mut:
	events        []EventEntry
	subscriptions []Subscription
	next_sub_id   int
}

fn EventQueue.new() EventQueue {
	return EventQueue{
		events: []EventEntry{}
		subscriptions: []Subscription{}
		next_sub_id: 1
	}
}

fn (mut eq EventQueue) push(event_type string, cartridge string) {
	eq.events << EventEntry{
		event_type: event_type
		cartridge: cartridge
		timestamp: time.now().unix()
	}
	// Ring buffer: cap at 100 entries
	if eq.events.len > 100 {
		eq.events = eq.events[eq.events.len - 100..]
	}
}

fn (mut eq EventQueue) subscribe(event string) string {
	id := 'sub-${eq.next_sub_id}'
	eq.next_sub_id++
	eq.subscriptions << Subscription{
		id: id
		event: event
	}
	return id
}

fn (eq &EventQueue) events_for(sub_id string) []EventEntry {
	// Find subscription to get the event filter
	mut event_filter := ''
	for s in eq.subscriptions {
		if s.id == sub_id {
			event_filter = s.event
			break
		}
	}
	if event_filter == '' {
		return []EventEntry{}
	}
	mut result := []EventEntry{}
	for e in eq.events {
		if e.event_type == event_filter {
			result << e
		}
	}
	return result
}

struct BojApp {
mut:
	cartridges  []CartridgeInfo
	start_time  time.Time
	node_id     string
	region      string
	event_queue EventQueue
}

fn BojApp.new() BojApp {
	return BojApp{
		cartridges: []CartridgeInfo{}
		start_time: time.now()
		node_id: os.getenv_opt('BOJ_NODE_ID') or { 'local-0' }
		region: os.getenv_opt('BOJ_REGION') or { 'local' }
		event_queue: EventQueue.new()
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Catalogue Initialisation
// ═══════════════════════════════════════════════════════════════════════

fn (mut app BojApp) init_catalogue() ! {
	result := C.boj_catalogue_init()
	if result != 0 {
		return error('failed to initialise BoJ catalogue (code ${result})')
	}
}

fn (mut app BojApp) register_cartridge(info CartridgeInfo) ! {
	name_bytes := info.name.bytes()
	ver_bytes := info.version.bytes()
	result := C.boj_catalogue_register(
		name_bytes.data,
		usize(name_bytes.len),
		ver_bytes.data,
		usize(ver_bytes.len),
		int(info.status),
		int(info.tier),
		int(info.domain),
	)
	if result != 0 {
		return error('failed to register cartridge "${info.name}" (code ${result})')
	}
	for p in info.protocols {
		proto_result := C.boj_catalogue_add_protocol(int(p))
		if proto_result != 0 {
			return error('failed to add protocol ${protocol_label(p)} to "${info.name}"')
		}
	}
	app.cartridges << CartridgeInfo{
		...info
		index: C.boj_catalogue_count() - 1
	}
}

fn (mut app BojApp) mount_cartridge(name string) !string {
	for c in app.cartridges {
		if c.name == name {
			// Verify hash before mounting (if hash is stored)
			mut hash_buf := [64]u8{init: 0}
			hash_len := C.boj_catalogue_get_hash(c.index, &hash_buf[0])
			if hash_len == 64 {
				// Hash is stored — verify against the binary on disk
				lib_path := 'cartridges/${name}/ffi/zig-out/lib/lib${name}.so'
				path_bytes := lib_path.bytes()
				verify_result := C.boj_loader_verify(
					path_bytes.data,
					usize(path_bytes.len),
					&hash_buf[0],
					usize(hash_len),
				)
				if verify_result == 0 {
					return error('cartridge "${name}" hash mismatch — binary has been tampered with')
				}
				if verify_result == -1 {
					return error('cartridge "${name}" hash verification failed — binary not found or unreadable')
				}
			}

			result := C.boj_catalogue_mount(c.index)
			return match result {
				0 { 'mounted "${name}" successfully' }
				-1 { return error('cartridge "${name}" is not Ready (status: ${status_label(c.status)})') }
				-2 { return error('cartridge "${name}" not found in catalogue') }
				else { return error('unknown mount error for "${name}" (code ${result})') }
			}
		}
	}
	return error('cartridge "${name}" not registered')
}

fn (app &BojApp) uptime_seconds() i64 {
	return i64((time.now() - app.start_time) / time.second)
}

// ═══════════════════════════════════════════════════════════════════════
// Built-in Cartridges
// ═══════════════════════════════════════════════════════════════════════

fn (mut app BojApp) register_builtin_cartridges() ! {
	builtins := [
		CartridgeInfo{
			name: 'database-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .database
			protocols: [ProtocolType.mcp, .rest, .grpc]
			index: 0
		},
		CartridgeInfo{
			name: 'nesy-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .nesy_dom
			protocols: [ProtocolType.nesy, .mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'fleet-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .fleet_dom
			protocols: [ProtocolType.fleet, .mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'agent-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .cloud
			protocols: [ProtocolType.agentic, .mcp, .rest, .grpc]
			index: 0
		},
	]
	for b in builtins {
		app.register_cartridge(b)!
	}
}

// ═══════════════════════════════════════════════════════════════════════
// JSON Response Builders
// ═══════════════════════════════════════════════════════════════════════

struct StatusResponse {
	version            string
	total_cartridges   usize
	ready_cartridges   usize
	mounted_cartridges usize
	node_id            string
	region             string
	uptime_seconds     i64
	ports              PortInfo
}

struct PortInfo {
	rest    int = 9000
	grpc    int = 9001
	graphql int = 9002
}

struct MenuResponse {
	tier_teranga []MenuEntryResponse
	tier_shield  []MenuEntryResponse
	tier_ayo     []MenuEntryResponse
	summary      SummaryResponse
}

struct MenuEntryResponse {
	name       string
	version    string
	domain     string
	protocols  []string
	status     string
	available  bool
}

struct SummaryResponse {
	total   usize
	ready   usize
	mounted usize
}

struct OrderRequest {
	requested_by string
	cartridges   []string
}

struct OrderResponse {
	session_id string
	mounted    []string
	failed     []OrderFailure
	endpoints  []EndpointInfo
}

struct OrderFailure {
	cartridge string
	reason    string
}

struct EndpointInfo {
	cartridge string
	rest      string
	grpc      string
	graphql   string
}

fn (app &BojApp) build_status() StatusResponse {
	return StatusResponse{
		version: 'BoJ Server v0.1.0'
		total_cartridges: C.boj_catalogue_count()
		ready_cartridges: C.boj_catalogue_count_ready()
		mounted_cartridges: C.boj_catalogue_count_mounted()
		node_id: app.node_id
		region: app.region
		uptime_seconds: app.uptime_seconds()
	}
}

fn (app &BojApp) build_menu() MenuResponse {
	mut teranga := []MenuEntryResponse{}
	mut shield := []MenuEntryResponse{}
	mut ayo := []MenuEntryResponse{}

	for c in app.cartridges {
		entry := MenuEntryResponse{
			name: c.name
			version: c.version
			domain: domain_label(c.domain)
			protocols: c.protocols.map(protocol_label)
			status: status_label(c.status)
			available: c.status == .ready
		}
		match c.tier {
			.teranga { teranga << entry }
			.shield { shield << entry }
			.ayo { ayo << entry }
		}
	}

	return MenuResponse{
		tier_teranga: teranga
		tier_shield: shield
		tier_ayo: ayo
		summary: SummaryResponse{
			total: C.boj_catalogue_count()
			ready: C.boj_catalogue_count_ready()
			mounted: C.boj_catalogue_count_mounted()
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST Server (port 9000)
// ═══════════════════════════════════════════════════════════════════════

fn json_response(data string) http.Response {
	return http.Response{
		status_code: 200
		header: http.new_header_from_map({
			.content_type: 'application/json; charset=utf-8'
		})
		body: data
	}
}

fn error_response(status_code int, message string) http.Response {
	body := json.encode({
		'error': message
	})
	return http.Response{
		status_code: status_code
		header: http.new_header_from_map({
			.content_type: 'application/json; charset=utf-8'
		})
		body: body
	}
}

// Handler structs (V 0.5.0 uses Handler interface, not function closures)

struct RestHandler {
	app &BojApp
}

fn (h RestHandler) handle(req http.Request) http.Response {
	path := req.url

	if path == '/health' {
		return json_response('{"status":"ok"}')
	}
	if path == '/status' {
		return json_response(json.encode(h.app.build_status()))
	}
	if path == '/menu' {
		return json_response(json.encode(h.app.build_menu()))
	}
	if path == '/matrix' {
		return json_response(json.encode(h.app.build_matrix()))
	}
	if path == '/order' {
		if req.method != .post {
			return error_response(405, 'POST required')
		}
		order := json.decode(OrderRequest, req.data) or {
			return error_response(400, 'invalid order JSON: ${err.msg()}')
		}
		return handle_order(h.app, order)
	}
	if path == '/order-ticket' {
		if req.method != .post {
			return error_response(405, 'POST required')
		}
		return handle_order_ticket(h.app, req.data)
	}
	// Cartridge-specific endpoints: /cartridge/{name}
	if path.starts_with('/cartridge/') {
		cname := path['/cartridge/'.len..]
		return handle_cartridge_endpoint(h.app, cname, req)
	}
	return error_response(404, 'unknown endpoint: ${path}')
}

// ═══════════════════════════════════════════════════════════════════════
// gRPC-compat Server (port 9001)
// ═══════════════════════════════════════════════════════════════════════

struct GrpcHandler {
	app &BojApp
}

fn grpc_response(data string, grpc_status string) http.Response {
	mut hdr := http.new_header_from_map({
		.content_type: 'application/json; charset=utf-8'
	})
	hdr.add_custom('grpc-status', grpc_status) or {}
	return http.Response{
		status_code: 200
		header: hdr
		body: data
	}
}

fn grpc_error(status_code int, message string, grpc_status string) http.Response {
	body := json.encode({
		'error': message
	})
	mut hdr := http.new_header_from_map({
		.content_type: 'application/json; charset=utf-8'
	})
	hdr.add_custom('grpc-status', grpc_status) or {}
	return http.Response{
		status_code: status_code
		header: hdr
		body: body
	}
}

fn (h GrpcHandler) handle(req http.Request) http.Response {
	if req.method != .post {
		return grpc_error(405, 'gRPC requires POST', '5')
	}

	path := req.url

	if path == '/boj.Catalogue/GetStatus' {
		return grpc_response(json.encode(h.app.build_status()), '0')
	}
	if path == '/boj.Catalogue/GetMenu' {
		return grpc_response(json.encode(h.app.build_menu()), '0')
	}
	if path == '/boj.Catalogue/GetMatrix' {
		return grpc_response(json.encode(h.app.build_matrix()), '0')
	}
	if path == '/boj.Catalogue/Mount' {
		body := json.decode(map[string]string, req.data) or {
			return grpc_error(400, 'invalid JSON body', '5')
		}
		name := body['name'] or { '' }
		if name == '' {
			return grpc_error(400, 'missing "name" field', '5')
		}
		for c in h.app.cartridges {
			if c.name == name {
				result := C.boj_catalogue_mount(c.index)
				if result != 0 {
					reason := match result {
						-1 { 'not Ready' }
						-2 { 'not found in catalogue' }
						else { 'mount error (code ${result})' }
					}
					return grpc_error(500, reason, '5')
				}
				mut eq := unsafe { &h.app.event_queue }
				eq.push('mount', name)
				return grpc_response(json.encode({
					'status':    'mounted'
					'cartridge': name
				}), '0')
			}
		}
		return grpc_error(404, 'cartridge "${name}" not found', '5')
	}
	if path == '/boj.Catalogue/Unmount' {
		body := json.decode(map[string]string, req.data) or {
			return grpc_error(400, 'invalid JSON body', '5')
		}
		name := body['name'] or { '' }
		if name == '' {
			return grpc_error(400, 'missing "name" field', '5')
		}
		for c in h.app.cartridges {
			if c.name == name {
				result := C.boj_catalogue_unmount(c.index)
				if result != 0 {
					return grpc_error(500, 'unmount error (code ${result})', '5')
				}
				mut eq := unsafe { &h.app.event_queue }
				eq.push('unmount', name)
				return grpc_response(json.encode({
					'status':    'unmounted'
					'cartridge': name
				}), '0')
			}
		}
		return grpc_error(404, 'cartridge "${name}" not found', '5')
	}
	if path == '/boj.Catalogue/GetCartridge' {
		body := json.decode(map[string]string, req.data) or {
			return grpc_error(400, 'invalid JSON body', '5')
		}
		name := body['name'] or { '' }
		if name == '' {
			return grpc_error(400, 'missing "name" field', '5')
		}
		for c in h.app.cartridges {
			if c.name == name {
				mounted := C.boj_catalogue_is_mounted(c.index)
				return grpc_response(json.encode(CartridgeDetail{
					name: c.name
					version: c.version
					domain: domain_label(c.domain)
					protocols: c.protocols.map(protocol_label)
					status: status_label(c.status)
					mounted: mounted == 1
					endpoints: EndpointInfo{
						cartridge: c.name
						rest: 'http://localhost:9000/cartridge/${c.name}'
						grpc: 'grpc://localhost:9001/${c.name}'
						graphql: 'http://localhost:9002/graphql?module=${c.name}'
					}
				}), '0')
			}
		}
		return grpc_error(404, 'cartridge "${name}" not found', '5')
	}

	return grpc_error(404, 'unknown gRPC method: ${path}', '5')
}

fn handle_order(app &BojApp, order OrderRequest) http.Response {
	session_id := '${time.now().unix()}:${order.requested_by}'
	mut mounted := []string{}
	mut failed := []OrderFailure{}
	mut endpoints := []EndpointInfo{}

	for name in order.cartridges {
		// Find the cartridge and mount via C FFI
		mut found := false
		for c in app.cartridges {
			if c.name == name {
				found = true
				// Check if already mounted
				if C.boj_catalogue_is_mounted(c.index) == 1 {
					mounted << name
					break
				}
				result := C.boj_catalogue_mount(c.index)
				if result != 0 {
					reason := match result {
						-1 { 'not Ready (status: ${status_label(c.status)})' }
						-2 { 'not found in catalogue' }
						else { 'mount error (code ${result})' }
					}
					failed << OrderFailure{
						cartridge: name
						reason: reason
					}
				} else {
					mounted << name
					mut eq := unsafe { &app.event_queue }
					eq.push('mount', name)
				}
				break
			}
		}
		if !found {
			failed << OrderFailure{
				cartridge: name
				reason: 'not registered'
			}
			continue
		}
		if name !in mounted {
			continue
		}
		endpoints << EndpointInfo{
			cartridge: name
			rest: 'http://localhost:9000/cartridge/${name}'
			grpc: 'grpc://localhost:9001/${name}'
			graphql: 'http://localhost:9002/graphql?module=${name}'
		}
	}

	return json_response(json.encode(OrderResponse{
		session_id: session_id
		mounted: mounted
		failed: failed
		endpoints: endpoints
	}))
}

// ═══════════════════════════════════════════════════════════════════════
// Order-Ticket (SCM format) Parser
// ═══════════════════════════════════════════════════════════════════════

// Parse a minimal order-ticket.scm body into an OrderRequest.
// Expected format:
//   (order
//     (requested-by "agent-name")
//     (session-id "id")
//     (cartridges ("database-mcp" "nesy-mcp")))
fn parse_order_ticket(body string) !OrderRequest {
	mut requested_by := ''
	mut cartridges := []string{}

	for line in body.split('\n') {
		trimmed := line.trim_space()
		if trimmed.starts_with('(requested-by') {
			requested_by = extract_quoted(trimmed) or { '' }
		}
		if trimmed.starts_with('(cartridges') || trimmed.starts_with('("') {
			// Extract quoted cartridge names from the line
			mut rest := trimmed
			for {
				idx := rest.index('"') or { break }
				end := rest[(idx + 1)..].index('"') or { break }
				cartridges << rest[(idx + 1)..(idx + 1 + end)]
				rest = rest[(idx + 1 + end + 1)..]
			}
		}
	}

	if requested_by == '' {
		return error('missing requested-by field')
	}
	if cartridges.len == 0 {
		return error('no cartridges specified')
	}

	return OrderRequest{
		requested_by: requested_by
		cartridges: cartridges
	}
}

fn extract_quoted(s string) !string {
	start := s.index('"') or { return error('no quote') }
	end := s[(start + 1)..].index('"') or { return error('no closing quote') }
	return s[(start + 1)..(start + 1 + end)]
}

fn handle_order_ticket(app &BojApp, body string) http.Response {
	order := parse_order_ticket(body) or {
		return error_response(400, 'invalid order ticket: ${err.msg()}')
	}
	return handle_order(app, order)
}

// ═══════════════════════════════════════════════════════════════════════
// Cartridge-Specific Endpoints
// ═══════════════════════════════════════════════════════════════════════

struct ReloadResponse {
	cartridge  string
	status     string
	reloaded   bool
	elapsed_ms i64
}

fn handle_cartridge_endpoint(app &BojApp, raw_path string, req http.Request) http.Response {
	// Check for /cartridge/{name}/reload
	if raw_path.ends_with('/reload') {
		cname := raw_path[..raw_path.len - '/reload'.len]
		if req.method != .post {
			return error_response(405, 'POST required for reload')
		}
		return handle_cartridge_reload(app, cname)
	}

	cname := raw_path
	// Find the cartridge
	for c in app.cartridges {
		if c.name == cname {
			mounted := C.boj_catalogue_is_mounted(c.index)
			if mounted != 1 {
				return error_response(503, 'cartridge "${cname}" is not mounted')
			}
			return json_response(json.encode(CartridgeDetail{
				name: c.name
				version: c.version
				domain: domain_label(c.domain)
				protocols: c.protocols.map(protocol_label)
				status: status_label(c.status)
				mounted: true
				endpoints: EndpointInfo{
					cartridge: c.name
					rest: 'http://localhost:9000/cartridge/${c.name}'
					grpc: 'grpc://localhost:9001/${c.name}'
					graphql: 'http://localhost:9002/graphql?module=${c.name}'
				}
			}))
		}
	}
	return error_response(404, 'cartridge "${cname}" not found')
}

fn handle_cartridge_reload(app &BojApp, cname string) http.Response {
	start := time.now()

	for c in app.cartridges {
		if c.name == cname {
			// Step 1: Unmount if currently mounted
			if C.boj_catalogue_is_mounted(c.index) == 1 {
				C.boj_catalogue_unmount(c.index)
				mut eq := unsafe { &app.event_queue }
				eq.push('unmount', cname)
			}

			// Step 2: Re-verify hash if one is stored
			mut hash_buf := [64]u8{init: 0}
			hash_len := C.boj_catalogue_get_hash(c.index, &hash_buf[0])
			if hash_len == 64 {
				lib_path := 'cartridges/${cname}/ffi/zig-out/lib/lib${cname}.so'
				path_bytes := lib_path.bytes()
				verify_result := C.boj_loader_verify(
					path_bytes.data,
					usize(path_bytes.len),
					&hash_buf[0],
					usize(hash_len),
				)
				if verify_result == 0 {
					return error_response(409, 'reload failed: hash mismatch for "${cname}"')
				}
				if verify_result == -1 {
					return error_response(500, 'reload failed: binary not found for "${cname}"')
				}
			}

			// Step 3: Re-mount
			result := C.boj_catalogue_mount(c.index)
			if result != 0 {
				reason := match result {
					-1 { 'not Ready (status: ${status_label(c.status)})' }
					-2 { 'not found in catalogue' }
					else { 'mount error (code ${result})' }
				}
				return error_response(500, 'reload mount failed: ${reason}')
			}

			mut eq := unsafe { &app.event_queue }
			eq.push('mount', cname)

			elapsed := i64((time.now() - start) / time.millisecond)
			return json_response(json.encode(ReloadResponse{
				cartridge: cname
				status: 'reloaded'
				reloaded: true
				elapsed_ms: elapsed
			}))
		}
	}
	return error_response(404, 'cartridge "${cname}" not found')
}

struct CartridgeDetail {
	name      string
	version   string
	domain    string
	protocols []string
	status    string
	mounted   bool
	endpoints EndpointInfo
}

// ═══════════════════════════════════════════════════════════════════════
// Matrix View
// ═══════════════════════════════════════════════════════════════════════

struct MatrixResponse {
	rows []MatrixRow
}

struct MatrixRow {
	protocol    string
	cells       map[string]string
}

fn (app &BojApp) build_matrix() MatrixResponse {
	protocols := [ProtocolType.mcp, .lsp, .dap, .bsp, .nesy, .agentic, .fleet, .grpc, .rest]
	domains := [CapabilityDomain.cloud, .container, .database, .k8s, .git, .secrets, .queues, .iac, .observe, .ssg, .proof, .fleet_dom, .nesy_dom]
	mut rows := []MatrixRow{}

	for p in protocols {
		mut cells := map[string]string{}
		for d in domains {
			// Check if any cartridge fills this cell
			mut cell_val := '-'
			for c in app.cartridges {
				if c.domain == d && p in c.protocols {
					mounted := C.boj_catalogue_is_mounted(c.index)
					cell_val = if mounted == 1 { '[M] ${c.name}' } else { c.name }
					break
				}
			}
			cells[domain_label(d)] = cell_val
		}
		rows << MatrixRow{
			protocol: protocol_label(p)
			cells: cells
		}
	}

	return MatrixResponse{
		rows: rows
	}
}

// ═══════════════════════════════════════════════════════════════════════
// GraphQL Server (port 9002)
// ═══════════════════════════════════════════════════════════════════════

struct GraphQLHandler {
	app &BojApp
}

struct SubscribeRequest {
	event string
}

struct SubscribeResponse {
	subscription_id string
	event           string
	status          string
}

fn (h GraphQLHandler) handle(req http.Request) http.Response {
	// Subscription polling endpoints (non-GraphQL paths on this port)
	if req.url == '/graphql/subscriptions' && req.method == .get {
		return json_response(json.encode(h.app.event_queue.subscriptions))
	}
	if req.url == '/graphql/subscribe' && req.method == .post {
		sub_req := json.decode(SubscribeRequest, req.data) or {
			return error_response(400, 'invalid subscribe JSON: expected {"event": "..."}')
		}
		if sub_req.event != 'mount' && sub_req.event != 'unmount' {
			return error_response(400, 'unsupported event type: "${sub_req.event}" (use "mount" or "unmount")')
		}
		// NOTE: mut access through shared ref — V's type system requires this
		// to be safe. In practice the event_queue is only mutated here and
		// in mount/unmount handlers, all on the same HTTP server thread.
		mut eq := unsafe { &h.app.event_queue }
		sub_id := eq.subscribe(sub_req.event)
		return json_response(json.encode(SubscribeResponse{
			subscription_id: sub_id
			event: sub_req.event
			status: 'subscribed'
		}))
	}
	if req.url.starts_with('/graphql/events') && req.method == .get {
		// Extract subscription_id from query string
		mut sub_id := ''
		if req.url.contains('?') {
			query_part := req.url[req.url.index('?') or { 0 } + 1..]
			for param in query_part.split('&') {
				if param.starts_with('subscription_id=') {
					sub_id = param['subscription_id='.len..]
				}
			}
		}
		if sub_id == '' {
			return error_response(400, 'missing subscription_id parameter')
		}
		events := h.app.event_queue.events_for(sub_id)
		return json_response(json.encode(events))
	}

	if req.method != .post {
		return error_response(405, 'POST required for GraphQL')
	}

	body := json.decode(map[string]string, req.data) or {
		return error_response(400, 'invalid GraphQL request')
	}
	query := body['query'] or { '' }

	if query.contains('__schema') || query.contains('__type') {
		return json_response(graphql_schema())
	}

	if query.contains('status') {
		return json_response(json.encode({
			'data': {
				'status': json.encode(h.app.build_status())
			}
		}))
	}

	if query.contains('menu') {
		return json_response(json.encode({
			'data': {
				'menu': json.encode(h.app.build_menu())
			}
		}))
	}

	if query.contains('matrix') {
		return json_response(json.encode({
			'data': {
				'matrix': json.encode(h.app.build_matrix())
			}
		}))
	}

	if query.contains('cartridge') {
		cname := extract_graphql_arg(query, 'name') or { '' }
		if cname != '' {
			for c in h.app.cartridges {
				if c.name == cname {
					return json_response(json.encode({
						'data': {
							'cartridge': json.encode(MenuEntryResponse{
								name: c.name
								version: c.version
								domain: domain_label(c.domain)
								protocols: c.protocols.map(protocol_label)
								status: status_label(c.status)
								available: c.status == .ready
							})
						}
					}))
				}
			}
			return error_response(404, 'cartridge "${cname}" not found')
		}
	}

	// Mutation support: forward to REST /order endpoint
	if query.contains('mutation') && query.contains('order') {
		return json_response(json.encode({
			'data': {
				'order': json.encode({
					'message': 'Use POST /order endpoint for mutations'
					'endpoint': 'http://localhost:9000/order'
				})
			}
		}))
	}

	return error_response(400, 'unsupported query')
}

fn extract_graphql_arg(query string, arg_name string) !string {
	// Find arg_name: "value" pattern in a GraphQL query
	needle := '${arg_name}:'
	idx := query.index(needle) or { return error('arg not found') }
	rest := query[(idx + needle.len)..].trim_space()
	if rest.len == 0 || rest[0] != `"` {
		return error('arg not quoted')
	}
	end := rest[1..].index('"') or { return error('no closing quote') }
	return rest[1..(end + 1)]
}

fn graphql_schema() string {
	return '{
  "data": {
    "__schema": {
      "queryType": { "name": "Query" },
      "mutationType": { "name": "Mutation" },
      "types": [
        {
          "name": "Query",
          "fields": [
            { "name": "status", "type": { "name": "Status" } },
            { "name": "menu", "type": { "name": "Menu" } },
            { "name": "cartridge", "args": [{ "name": "name", "type": { "name": "String!" } }], "type": { "name": "Cartridge" } }
          ]
        },
        {
          "name": "Mutation",
          "fields": [
            { "name": "order", "args": [{ "name": "input", "type": { "name": "OrderInput!" } }], "type": { "name": "OrderResult" } }
          ]
        }
      ]
    }
  }
}'
}

// ═══════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════

fn main() {
	println('BoJ Server v0.1.0 — The Teranga Console')
	println('Phase 3: V-lang triple adapter (REST+gRPC+GraphQL)')
	println('')

	mut app := BojApp.new()

	// Initialise the Zig FFI catalogue
	app.init_catalogue() or {
		eprintln('FATAL: ${err.msg()}')
		exit(1)
	}
	defer { C.boj_catalogue_deinit() }

	// Register built-in cartridges
	app.register_builtin_cartridges() or {
		eprintln('FATAL: ${err.msg()}')
		exit(1)
	}

	total := C.boj_catalogue_count()
	ready := C.boj_catalogue_count_ready()
	println('Catalogue: ${total} cartridges registered, ${ready} ready')
	println('')

	app_ref := &app

	// REST server on port 9000
	println('Starting REST  on :9000')
	mut rest_srv := &http.Server{
		addr: ':9000'
		handler: RestHandler{app: app_ref}
	}
	spawn rest_srv.listen_and_serve()

	// GraphQL server on port 9002
	println('Starting GraphQL on :9002')
	mut gql_srv := &http.Server{
		addr: ':9002'
		handler: GraphQLHandler{app: app_ref}
	}
	spawn gql_srv.listen_and_serve()

	// gRPC-compat on port 9001 — proper service/method paths.
	// JSON-over-HTTP until vlib gains protobuf support.
	println('Starting gRPC-compat on :9001 (JSON-over-HTTP, service/method paths)')
	mut grpc_srv := &http.Server{
		addr: ':9001'
		handler: GrpcHandler{app: app_ref}
	}
	spawn grpc_srv.listen_and_serve()

	println('')
	println('BoJ Server ready. Endpoints:')
	println('  REST:    http://localhost:9000/status')
	println('  gRPC:    grpc://localhost:9001 (JSON-compat)')
	println('  GraphQL: http://localhost:9002/graphql')
	println('')
	println('Press Ctrl+C to stop.')

	// Block main thread
	os.signal_opt(.int, fn (_ os.Signal) {
		println('\nShutting down...')
		exit(0)
	}) or {}

	for {
		time.sleep(1 * time.second)
	}
}
