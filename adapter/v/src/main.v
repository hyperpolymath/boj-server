// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — V-lang Triple Adapter
//
// The unified console that exposes mounted cartridges as:
//   - REST  (port 7700)
//   - gRPC  (port 7701)
//   - GraphQL (port 7702)
//
// Phase 3 of the BoJ pipeline:
//   Idris2 ABI (proofs) → Zig FFI (execution) → V-lang Adapter (network)

module main

import json
import net
import net.http
import os
import time

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against libboJ catalogue built from Zig)
// ═══════════════════════════════════════════════════════════════════════

#flag -L../../ffi/zig/zig-out/lib
// NOTE: libboj_loader includes catalogue symbols (loader imports catalogue),
// so we only link loader to avoid duplicate symbol errors.
// #flag -lboj_catalogue  — included transitively via loader
#flag -lboj_loader
#flag -lboj_federation
#flag -lboj_coprocessor
#flag -lboj_sla
#flag -lboj_community
#flag -lboj_sdp
#flag -L../../cartridges/container-mcp/ffi/zig-out/lib
#flag -lcontainer_mcp
#flag -L../../cartridges/feedback-mcp/ffi/zig-out/lib
#flag -lfeedback_mcp

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
fn C.boj_catalogue_set_backend(backend_ptr &u8, backend_len usize) int
fn C.boj_menu_backend(index usize, out_ptr &u8, out_len usize) usize
fn C.boj_menu_name(index usize, out_ptr &u8, out_len usize) usize
fn C.boj_menu_json(out_ptr &u8, out_len usize) usize
fn C.boj_loader_verify(path_ptr &u8, path_len usize, expected_hex_ptr &u8, expected_hex_len usize) int

// Umoja federation C FFI declarations
fn C.boj_federation_init() int
fn C.umoja_set_node_id(id_ptr &u8, id_len usize) int
fn C.umoja_bind(port u16) int
fn C.umoja_bind_quic(port u16) int
fn C.umoja_unbind() int
fn C.umoja_is_bound() int
fn C.umoja_transport_mode() int
fn C.umoja_add_peer(host_ptr &u8, host_len usize, port u16) int
fn C.umoja_peer_count() usize
fn C.umoja_gossip_round_count() usize
fn C.umoja_quic_key_exchange(peer_idx usize) int
fn C.umoja_quic_session_established(peer_idx usize) int
fn C.umoja_send_heartbeat(peer_idx usize) int
fn C.umoja_discover_udp(target_ptr &u8, target_len usize, target_port u16) int
fn C.umoja_packets_sent() usize
fn C.umoja_packets_received() usize

// Coprocessor dispatch C FFI declarations
fn C.boj_coprocessor_init() int
fn C.boj_coprocessor_deinit()
fn C.boj_coprocessor_device_count() usize
fn C.boj_coprocessor_device_kind(idx usize) u8
fn C.boj_coprocessor_device_status(idx usize) u8
fn C.boj_coprocessor_device_dispatches(idx usize) u64
fn C.boj_coprocessor_register(name_ptr &u8, name_len usize, kinds_ptr &u8, kinds_len usize) int
fn C.boj_coprocessor_select_by_name(name_ptr &u8, name_len usize, was_fallback &u8) u8
fn C.boj_coprocessor_affinity_count() usize
fn C.boj_coprocessor_has_accelerator(kind u8) u8

// SLA & Monitoring C FFI declarations
fn C.boj_sla_init() int
fn C.boj_sla_deinit()
fn C.boj_sla_register(name_ptr &u8, name_len usize, tier u8) int
fn C.boj_sla_record_invocation(idx usize, latency_us u32, success u8)
fn C.boj_sla_record_health(idx usize, healthy u8)
fn C.boj_sla_uptime(idx usize) u32
fn C.boj_sla_error_rate(idx usize) u32
fn C.boj_sla_p50(idx usize) u32
fn C.boj_sla_p95(idx usize) u32
fn C.boj_sla_p99(idx usize) u32
fn C.boj_sla_meets_target(idx usize) u8
fn C.boj_sla_total_requests() u64
fn C.boj_sla_total_errors() u64
fn C.boj_sla_cartridge_count() usize

// Community cartridge submission C FFI declarations
fn C.boj_community_init() int
fn C.boj_community_deinit()
fn C.boj_community_submit(name_ptr &u8, name_len usize, author_ptr &u8, author_len usize, desc_ptr &u8, desc_len usize, hash_ptr &u8, hash_len usize) int
fn C.boj_community_set_status(idx usize, status u8) int
fn C.boj_community_status(idx usize) u8
fn C.boj_community_count() usize
fn C.boj_community_count_approved() usize
fn C.boj_community_count_pending() usize
fn C.boj_community_find(name_ptr &u8, name_len usize) int

// Feedback-MCP C FFI declarations (feedback-o-tron state machine)
fn C.fb_register(channel_type int) int
fn C.fb_start_collecting(slot_idx int) int
fn C.fb_submit(slot_idx int, sentiment int) int
fn C.fb_state(slot_idx int) int
fn C.fb_count(slot_idx int) int
fn C.fb_positive_count(slot_idx int) int
fn C.fb_negative_count(slot_idx int) int
fn C.fb_neutral_count(slot_idx int) int
fn C.fb_deregister(slot_idx int) int
fn C.fb_can_transition(from int, to int) int
fn C.fb_reset()
fn C.boj_cartridge_init() int

// Auto-SDP C FFI declarations
fn C.boj_sdp_init() int
fn C.boj_sdp_deinit()
fn C.boj_sdp_authorise(id_ptr &u8, id_len usize, rate_limit u32) int
fn C.boj_sdp_check(id_ptr &u8, id_len usize) u8
fn C.boj_sdp_set_open_mode(mode u8)
fn C.boj_sdp_peer_count() usize
fn C.boj_sdp_ban_count() usize

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
	feedback = 14
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
		.feedback { 'Feedback' }
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
	index     int
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
		index: int(C.boj_catalogue_count()) - 1
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
		CartridgeInfo{
			name: 'cloud-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .cloud
			protocols: [ProtocolType.mcp, .rest, .grpc]
			index: 0
		},
		CartridgeInfo{
			name: 'container-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .container
			protocols: [ProtocolType.mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'k8s-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .k8s
			protocols: [ProtocolType.mcp, .rest, .grpc]
			index: 0
		},
		CartridgeInfo{
			name: 'git-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .git
			protocols: [ProtocolType.mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'secrets-mcp'
			version: '0.1.0'
			status: .ready
			tier: .shield
			domain: .secrets
			protocols: [ProtocolType.mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'queues-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .queues
			protocols: [ProtocolType.mcp, .rest, .grpc]
			index: 0
		},
		CartridgeInfo{
			name: 'iac-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .iac
			protocols: [ProtocolType.mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'observe-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .observe
			protocols: [ProtocolType.mcp, .rest, .grpc]
			index: 0
		},
		CartridgeInfo{
			name: 'ssg-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .ssg
			protocols: [ProtocolType.mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'proof-mcp'
			version: '0.1.0'
			status: .ready
			tier: .shield
			domain: .proof
			protocols: [ProtocolType.mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'lsp-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .cloud
			protocols: [ProtocolType.lsp, .mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'dap-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .cloud
			protocols: [ProtocolType.dap, .mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'bsp-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .cloud
			protocols: [ProtocolType.bsp, .mcp, .rest]
			index: 0
		},
		CartridgeInfo{
			name: 'feedback-mcp'
			version: '0.1.0'
			status: .ready
			tier: .teranga
			domain: .feedback
			protocols: [ProtocolType.mcp, .rest]
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
	total_cartridges   int
	ready_cartridges   int
	mounted_cartridges int
	node_id            string
	region             string
	uptime_seconds     i64
	ports              PortInfo
}

struct PortInfo {
	rest    int = 7700
	grpc    int = 7701
	graphql int = 7702
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
	total   int
	ready   int
	mounted int
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
		total_cartridges: int(C.boj_catalogue_count())
		ready_cartridges: int(C.boj_catalogue_count_ready())
		mounted_cartridges: int(C.boj_catalogue_count_mounted())
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
			total: int(C.boj_catalogue_count())
			ready: int(C.boj_catalogue_count_ready())
			mounted: int(C.boj_catalogue_count_mounted())
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
	// GET /cartridges — list all cartridges
	if path == '/cartridges' {
		return json_response(json.encode(h.app.build_matrix()))
	}
	// Cartridge-specific endpoints: /cartridge/{name} and /cartridges/{name}
	if path.starts_with('/cartridge/') {
		cname := path['/cartridge/'.len..]
		return handle_cartridge_endpoint(h.app, cname, req)
	}
	if path.starts_with('/cartridges/') {
		cname := path['/cartridges/'.len..]
		return handle_cartridge_endpoint(h.app, cname, req)
	}
	// --- Umoja Federation endpoints ---
	if path == '/umoja/status' {
		return handle_umoja_status(h.app)
	}
	if path == '/umoja/peers' && req.method == .post {
		return handle_umoja_add_peer(req.data)
	}
	if path == '/umoja/peers' {
		return handle_umoja_peers()
	}
	if path == '/umoja/transport' {
		return json_response(json.encode({
			'mode': if C.umoja_transport_mode() == 1 { 'quic' } else { 'udp' }
		}))
	}
	if path == '/coprocessor/status' {
		return handle_coprocessor_status()
	}
	if path == '/coprocessor/select' && req.method == .post {
		return handle_coprocessor_select(req.data)
	}
	if path == '/sla/status' {
		return handle_sla_status()
	}
	if path == '/community/submissions' && req.method == .get {
		return handle_community_list()
	}
	if path == '/community/submit' && req.method == .post {
		return handle_community_submit(req.data)
	}
	if path == '/sdp/status' {
		return handle_sdp_status()
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
						rest: 'http://localhost:7700/cartridge/${c.name}'
						grpc: 'grpc://localhost:7701/${c.name}'
						graphql: 'http://localhost:7702/graphql?module=${c.name}'
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
			rest: 'http://localhost:7700/cartridge/${name}'
			grpc: 'grpc://localhost:7701/${name}'
			graphql: 'http://localhost:7702/graphql?module=${name}'
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

	// POST /cartridge/{name}/invoke — invoke a tool on a mounted cartridge
	if raw_path.ends_with('/invoke') {
		cname := raw_path[..raw_path.len - '/invoke'.len]
		if req.method != .post {
			return error_response(405, 'POST required for invoke')
		}
		return handle_cartridge_invoke(app, cname, req.data)
	}

	// POST /cartridge/{name}/load — mount a cartridge
	if raw_path.ends_with('/load') {
		cname := raw_path[..raw_path.len - '/load'.len]
		if req.method != .post {
			return error_response(405, 'POST required for load')
		}
		for c in app.cartridges {
			if c.name == cname {
				result := C.boj_catalogue_mount(c.index)
				if result != 0 {
					reason := match result {
						-1 { 'not Ready' }
						-2 { 'not found in catalogue' }
						else { 'mount error (code ${result})' }
					}
					return error_response(500, reason)
				}
				mut eq := unsafe { &app.event_queue }
				eq.push('mount', cname)
				return json_response(json.encode({
					'status':    'mounted'
					'cartridge': cname
				}))
			}
		}
		return error_response(404, 'cartridge "${cname}" not found')
	}

	// POST /cartridge/{name}/unload — unmount a cartridge
	if raw_path.ends_with('/unload') {
		cname := raw_path[..raw_path.len - '/unload'.len]
		if req.method != .post {
			return error_response(405, 'POST required for unload')
		}
		for c in app.cartridges {
			if c.name == cname {
				result := C.boj_catalogue_unmount(c.index)
				if result != 0 {
					return error_response(500, 'unmount error (code ${result})')
				}
				mut eq := unsafe { &app.event_queue }
				eq.push('unmount', cname)
				return json_response(json.encode({
					'status':    'unmounted'
					'cartridge': cname
				}))
			}
		}
		return error_response(404, 'cartridge "${cname}" not found')
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
					rest: 'http://localhost:7700/cartridge/${c.name}'
					grpc: 'grpc://localhost:7701/${c.name}'
					graphql: 'http://localhost:7702/graphql?module=${c.name}'
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

// ═══════════════════════════════════════════════════════════════════════
// Cartridge Tool Invocation (Grade C: real work, not just state machines)
// ═══════════════════════════════════════════════════════════════════════

struct InvokeRequest {
	tool string
	args string
}

fn handle_cartridge_invoke(app &BojApp, cname string, body string) http.Response {
	// Verify cartridge exists and is mounted
	mut found := false
	for c in app.cartridges {
		if c.name == cname {
			found = true
			mounted := C.boj_catalogue_is_mounted(c.index)
			if mounted != 1 {
				return error_response(503, 'cartridge "${cname}" is not mounted — POST /cartridges/${cname}/load first')
			}
			break
		}
	}
	if !found {
		return error_response(404, 'cartridge "${cname}" not found')
	}

	// Parse the invoke request
	invoke_req := json.decode(InvokeRequest, body) or {
		return error_response(400, 'invalid invoke JSON: ${err.msg()} — expected {"tool": "...", "args": "..."}')
	}

	// Dispatch to cartridge-specific tool handlers
	if cname == 'database-mcp' { return invoke_database(invoke_req.tool, invoke_req.args) }
	if cname == 'ssg-mcp' { return invoke_ssg(invoke_req.tool, invoke_req.args) }
	if cname == 'container-mcp' { return invoke_container(invoke_req.tool, invoke_req.args) }
	if cname == 'observe-mcp' { return invoke_observe(invoke_req.tool, invoke_req.args) }
	if cname == 'git-mcp' { return invoke_git(invoke_req.tool, invoke_req.args) }
	if cname == 'proof-mcp' { return invoke_proof(invoke_req.tool, invoke_req.args) }
	if cname == 'cloud-mcp' { return invoke_cloud(invoke_req.tool, invoke_req.args) }
	if cname == 'k8s-mcp' { return invoke_k8s(invoke_req.tool, invoke_req.args) }
	if cname == 'secrets-mcp' { return invoke_secrets(invoke_req.tool, invoke_req.args) }
	if cname == 'queues-mcp' { return invoke_queues(invoke_req.tool, invoke_req.args) }
	if cname == 'iac-mcp' { return invoke_iac(invoke_req.tool, invoke_req.args) }
	if cname == 'agent-mcp' { return invoke_agent(invoke_req.tool, invoke_req.args) }
	if cname == 'nesy-mcp' { return invoke_nesy(invoke_req.tool, invoke_req.args) }
	if cname == 'fleet-mcp' { return invoke_fleet(invoke_req.tool, invoke_req.args) }
	if cname == 'lsp-mcp' { return invoke_lsp(invoke_req.tool, invoke_req.args) }
	if cname == 'dap-mcp' { return invoke_dap(invoke_req.tool, invoke_req.args) }
	if cname == 'bsp-mcp' { return invoke_bsp(invoke_req.tool, invoke_req.args) }
	if cname == 'feedback-mcp' { return invoke_feedback(invoke_req.tool, invoke_req.args) }

	// All 18 cartridges should have handlers above — this is a safety fallback
	return json_response(json.encode({
		'cartridge': cname
		'tool':      invoke_req.tool
		'status':    'acknowledged'
		'message':   'Tool handler not yet implemented for ${cname}. State machine only.'
	}))
}

// --- database-mcp: VeriSimDB + general database operations ---

fn invoke_database(tool string, args string) http.Response {
	// VeriSimDB endpoint — configurable via VERISIMDB_URL env var
	verisimdb_url := os.getenv_opt('VERISIMDB_URL') or { 'http://localhost:8180' }

	if tool == 'health' {
		result := os.execute('curl -sf --max-time 3 ${verisimdb_url}/health 2>/dev/null')
		if result.exit_code == 0 {
			return json_response(json.encode({
				'tool':   'health'
				'status': 'ok'
				'data':   result.output.trim_space()
			}))
		}
		return json_response(json.encode({
			'tool':   'health'
			'status': 'unreachable'
			'error':  'VeriSimDB not responding at ${verisimdb_url}'
		}))
	}
	if tool == 'list_octads' {
		result := os.execute('curl -sf --max-time 5 ${verisimdb_url}/octads 2>/dev/null')
		if result.exit_code == 0 {
			return json_response(json.encode({
				'tool':   'list_octads'
				'status': 'ok'
				'data':   result.output.trim_space()
			}))
		}
		return json_response(json.encode({
			'tool':   'list_octads'
			'status': 'error'
			'error':  'Failed to list octads: ${result.output.trim_space()}'
		}))
	}
	if tool == 'create_octad' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'create_octad requires {"name": "...", "type": "service|entity|resource"}')
		}
		name := params['name'] or { '' }
		entity_type := params['type'] or { 'entity' }
		if name == '' {
			return error_response(400, 'create_octad requires "name"')
		}
		body := '{"name":"${name}","type":"${entity_type}"}'
		result := os.execute("curl -sf --max-time 5 -X POST -H 'Content-Type: application/json' -d '${body}' ${verisimdb_url}/octads 2>/dev/null")
		return json_response(json.encode({
			'tool':   'create_octad'
			'name':   name
			'status': if result.exit_code == 0 { 'created' } else { 'error' }
			'data':   result.output.trim_space()
		}))
	}
	if tool == 'query' {
		result := os.execute("curl -sf --max-time 5 -X POST -H 'Content-Type: application/json' -d '${args}' ${verisimdb_url}/vql/execute 2>/dev/null")
		if result.exit_code == 0 {
			return json_response(json.encode({
				'tool':   'query'
				'status': 'ok'
				'data':   result.output.trim_space()
			}))
		}
		return json_response(json.encode({
			'tool':   'query'
			'status': 'error'
			'error':  'VQL query failed: ${result.output.trim_space()}'
		}))
	}
	if tool == 'drift' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'drift requires {"id": "octad-id"}')
		}
		entity_id := params['id'] or { '' }
		if entity_id == '' {
			return error_response(400, 'drift requires "id"')
		}
		result := os.execute('curl -sf --max-time 5 ${verisimdb_url}/drift/entity/${entity_id} 2>/dev/null')
		return json_response(json.encode({
			'tool':   'drift'
			'id':     entity_id
			'status': if result.exit_code == 0 { 'ok' } else { 'error' }
			'data':   result.output.trim_space()
		}))
	}
	if tool == 'list_backends' {
		return json_response(json.encode({
			'tool':     'list_backends'
			'backends': 'verisimdb,postgresql,sqlite,redis'
		}))
	}
	return error_response(400, 'unknown database-mcp tool: "${tool}" — available: health, list_octads, create_octad, query, drift, list_backends')
}

// --- ssg-mcp: Static site generation (Zola, Hugo, ddraig) ---

fn invoke_ssg(tool string, args string) http.Response {
	if tool == 'build' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'ssg build requires {"engine": "zola|hugo", "path": "/path/to/site"}')
		}
		engine := params['engine'] or { 'zola' }
		site_path := params['path'] or { '.' }

		mut cmd := ''
		if engine == 'zola' { cmd = 'cd ${site_path} && zola build 2>&1' }
		else if engine == 'hugo' { cmd = 'cd ${site_path} && hugo 2>&1' }
		else if engine == 'ddraig' { cmd = 'cd ${site_path} && ddraig build 2>&1' }
		else { return error_response(400, 'unknown SSG engine: "${engine}" — use zola, hugo, or ddraig') }

		result := os.execute(cmd)
		status_str := if result.exit_code == 0 { 'success' } else { 'failed' }
		return json_response(json.encode({
			'tool':      'build'
			'engine':    engine
			'path':      site_path
			'exit_code': result.exit_code.str()
			'output':    result.output
			'status':    status_str
		}))
	}
	if tool == 'preview' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'ssg preview requires {"engine": "zola|hugo", "path": "/path/to/site"}')
		}
		engine := params['engine'] or { 'zola' }
		site_path := params['path'] or { '.' }

		check := os.execute('pgrep -f "${engine} serve" 2>/dev/null')
		if check.exit_code == 0 {
			return json_response(json.encode({
				'tool':    'preview'
				'status':  'already_running'
				'message': '${engine} preview server already running (PID: ${check.output.trim_space()})'
			}))
		}
		os.execute('cd ${site_path} && nohup ${engine} serve --port 1111 &>/dev/null &')
		return json_response(json.encode({
			'tool':   'preview'
			'status': 'started'
			'url':    'http://localhost:1111'
			'engine': engine
		}))
	}
	if tool == 'list_engines' {
		mut engines := []string{}
		if os.execute('command -v zola').exit_code == 0 { engines << 'zola' }
		if os.execute('command -v hugo').exit_code == 0 { engines << 'hugo' }
		if os.execute('command -v ddraig').exit_code == 0 { engines << 'ddraig' }
		return json_response(json.encode({
			'tool':      'list_engines'
			'available': engines.join(',')
		}))
	}
	return error_response(400, 'unknown ssg-mcp tool: "${tool}" — available: build, preview, list_engines')
}

// --- container-mcp: Container lifecycle + Stapeln integration ---
// Combines three layers:
//   1. Podman CLI — direct container operations (list, build, images)
//   2. Zig FFI state machine — formal lifecycle tracking (slots, transitions)
//   3. Stapeln API — stack validation, security scanning, gap analysis, codegen

fn C.ctr_build(runtime int, image_name &u8) int
fn C.ctr_create(slot_idx int) int
fn C.ctr_start(slot_idx int) int
fn C.ctr_stop(slot_idx int) int
fn C.ctr_remove(slot_idx int) int
fn C.ctr_state(slot_idx int) int
fn C.ctr_can_transition(from int, to int) int
fn C.ctr_reset()

fn ctr_state_label(s int) string {
	return match s {
		0 { 'none' }
		1 { 'built' }
		2 { 'created' }
		3 { 'running' }
		4 { 'stopped' }
		5 { 'removed' }
		else { 'unknown' }
	}
}

fn invoke_container(tool string, args string) http.Response {
	// --- Podman CLI tools ---
	if tool == 'list' {
		result := os.execute('podman ps --format json 2>/dev/null')
		status_str := if result.exit_code == 0 { 'ok' } else { 'error' }
		data_str := if result.exit_code == 0 { result.output } else { 'podman not available or not running' }
		return json_response(json.encode({
			'tool':   'list'
			'status': status_str
			'data':   data_str
		}))
	}
	if tool == 'build' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'container build requires {"path": "/path/to/project", "tag": "image:tag"}')
		}
		build_path := params['path'] or { '.' }
		tag := params['tag'] or { 'boj-build:latest' }
		runtime_name := params['runtime'] or { 'podman' }

		// Allocate a state machine slot for lifecycle tracking
		runtime_int := match runtime_name {
			'podman' { 1 }
			'nerdctl' { 2 }
			'docker' { 3 }
			else { 1 }
		}
		slot := C.ctr_build(runtime_int, tag.str)

		// Actually build via CLI
		result := os.execute('cd ${build_path} && podman build -t ${tag} -f Containerfile . 2>&1')
		status_str := if result.exit_code == 0 { 'success' } else { 'failed' }
		return json_response(json.encode({
			'tool':      'build'
			'tag':       tag
			'slot':      slot.str()
			'state':     ctr_state_label(C.ctr_state(slot))
			'exit_code': result.exit_code.str()
			'output':    result.output
			'status':    status_str
		}))
	}
	if tool == 'images' {
		result := os.execute('podman images --format json 2>/dev/null')
		status_str := if result.exit_code == 0 { 'ok' } else { 'error' }
		return json_response(json.encode({
			'tool':   'images'
			'status': status_str
			'data':   result.output
		}))
	}

	// --- FFI state machine tools ---
	if tool == 'create' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'create requires {"slot": "0"}')
		}
		slot := (params['slot'] or { '0' }).int()
		result := C.ctr_create(slot)
		if result == -1 {
			return error_response(404, 'slot ${slot} not active')
		}
		if result == -2 {
			return error_response(409, 'cannot create from state: ${ctr_state_label(C.ctr_state(slot))}')
		}
		return json_response(json.encode({
			'tool':   'create'
			'slot':   slot.str()
			'state':  ctr_state_label(C.ctr_state(slot))
			'status': 'ok'
		}))
	}
	if tool == 'start' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'start requires {"slot": "0"}')
		}
		slot := (params['slot'] or { '0' }).int()
		result := C.ctr_start(slot)
		if result == -1 {
			return error_response(404, 'slot ${slot} not active')
		}
		if result == -2 {
			return error_response(409, 'cannot start from state: ${ctr_state_label(C.ctr_state(slot))}')
		}
		return json_response(json.encode({
			'tool':   'start'
			'slot':   slot.str()
			'state':  ctr_state_label(C.ctr_state(slot))
			'status': 'ok'
		}))
	}
	if tool == 'stop' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'stop requires {"slot": "0"}')
		}
		slot := (params['slot'] or { '0' }).int()
		result := C.ctr_stop(slot)
		if result == -1 {
			return error_response(404, 'slot ${slot} not active')
		}
		if result == -2 {
			return error_response(409, 'cannot stop from state: ${ctr_state_label(C.ctr_state(slot))}')
		}
		return json_response(json.encode({
			'tool':   'stop'
			'slot':   slot.str()
			'state':  ctr_state_label(C.ctr_state(slot))
			'status': 'ok'
		}))
	}
	if tool == 'remove' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'remove requires {"slot": "0"}')
		}
		slot := (params['slot'] or { '0' }).int()
		result := C.ctr_remove(slot)
		if result == -1 {
			return error_response(404, 'slot ${slot} not active')
		}
		if result == -2 {
			return error_response(409, 'cannot remove from state: ${ctr_state_label(C.ctr_state(slot))} — stop first')
		}
		return json_response(json.encode({
			'tool':   'remove'
			'slot':   slot.str()
			'state':  ctr_state_label(C.ctr_state(slot))
			'status': 'ok'
		}))
	}
	if tool == 'inspect' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'inspect requires {"slot": "0"}')
		}
		slot := (params['slot'] or { '0' }).int()
		state := C.ctr_state(slot)
		return json_response(json.encode({
			'tool':  'inspect'
			'slot':  slot.str()
			'state': ctr_state_label(state)
		}))
	}
	if tool == 'logs' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'logs requires {"name": "container-name"}')
		}
		name := params['name'] or { '' }
		if name == '' {
			return error_response(400, 'logs requires {"name": "container-name"}')
		}
		result := os.execute('podman logs ${name} 2>&1')
		status_str := if result.exit_code == 0 { 'ok' } else { 'error' }
		return json_response(json.encode({
			'tool':   'logs'
			'name':   name
			'status': status_str
			'data':   result.output
		}))
	}

	// --- Stapeln integration tools ---
	stapeln_url := os.getenv_opt('STAPELN_URL') or { 'http://localhost:4000' }

	if tool == 'stapeln_stacks' {
		resp := http.get('${stapeln_url}/api/stacks') or {
			return error_response(502, 'stapeln not reachable at ${stapeln_url}: ${err.msg()}')
		}
		return json_response(json.encode({
			'tool':   'stapeln_stacks'
			'status': if resp.status_code == 200 { 'ok' } else { 'error' }
			'data':   resp.body
		}))
	}
	if tool == 'stapeln_validate' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'stapeln_validate requires {"stack_id": "1"}')
		}
		stack_id := params['stack_id'] or { '1' }
		resp := http.post('${stapeln_url}/api/stacks/${stack_id}/validate', '') or {
			return error_response(502, 'stapeln not reachable: ${err.msg()}')
		}
		return json_response(json.encode({
			'tool':   'stapeln_validate'
			'status': if resp.status_code == 200 { 'ok' } else { 'error' }
			'data':   resp.body
		}))
	}
	if tool == 'stapeln_security' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'stapeln_security requires {"stack_id": "1"}')
		}
		stack_id := params['stack_id'] or { '1' }
		resp := http.post('${stapeln_url}/api/stacks/${stack_id}/security-scan', '') or {
			return error_response(502, 'stapeln not reachable: ${err.msg()}')
		}
		return json_response(json.encode({
			'tool':   'stapeln_security'
			'status': if resp.status_code == 200 { 'ok' } else { 'error' }
			'data':   resp.body
		}))
	}
	if tool == 'stapeln_gaps' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'stapeln_gaps requires {"stack_id": "1"}')
		}
		stack_id := params['stack_id'] or { '1' }
		resp := http.post('${stapeln_url}/api/stacks/${stack_id}/gap-analysis', '') or {
			return error_response(502, 'stapeln not reachable: ${err.msg()}')
		}
		return json_response(json.encode({
			'tool':   'stapeln_gaps'
			'status': if resp.status_code == 200 { 'ok' } else { 'error' }
			'data':   resp.body
		}))
	}
	if tool == 'stapeln_generate' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'stapeln_generate requires {"stack_id": "1", "format": "docker_compose"}')
		}
		stack_id := params['stack_id'] or { '1' }
		format := params['format'] or { 'all' }
		resp := http.post('${stapeln_url}/api/stacks/${stack_id}/generate?format=${format}', '') or {
			return error_response(502, 'stapeln not reachable: ${err.msg()}')
		}
		return json_response(json.encode({
			'tool':   'stapeln_generate'
			'format': format
			'status': if resp.status_code == 200 { 'ok' } else { 'error' }
			'data':   resp.body
		}))
	}
	return error_response(400, 'unknown container-mcp tool: "${tool}" — available: list, build, images, create, start, stop, remove, inspect, logs, stapeln_stacks, stapeln_validate, stapeln_security, stapeln_gaps, stapeln_generate')
}

// --- observe-mcp: Observability and feedback ---

fn invoke_observe(tool string, args string) http.Response {
	if tool == 'status' {
		return json_response(json.encode({
			'tool':       'status'
			'boj_uptime': 'running'
			'cartridges': int(C.boj_catalogue_count()).str()
			'ready':      int(C.boj_catalogue_count_ready()).str()
			'mounted':    int(C.boj_catalogue_count_mounted()).str()
		}))
	}
	if tool == 'feedback' {
		result := os.execute('curl -sf --max-time 3 http://localhost:4000/api/v1/status 2>/dev/null')
		if result.exit_code == 0 {
			return json_response(json.encode({
				'tool':   'feedback'
				'status': 'connected'
				'data':   result.output
			}))
		}
		return json_response(json.encode({
			'tool':   'feedback'
			'status': 'disconnected'
			'error':  'feedback-o-tron not running at localhost:4000'
		}))
	}
	return error_response(400, 'unknown observe-mcp tool: "${tool}" — available: status, feedback')
}

// --- git-mcp: Git forge operations ---

fn invoke_git(tool string, args string) http.Response {
	if tool == 'repos' {
		result := os.execute('gh repo list --json name,url,isPrivate --limit 20 2>/dev/null')
		status_str := if result.exit_code == 0 { 'ok' } else { 'error' }
		data_str := if result.exit_code == 0 { result.output } else { 'gh CLI not available or not authenticated' }
		return json_response(json.encode({
			'tool':   'repos'
			'status': status_str
			'data':   data_str
		}))
	}
	if tool == 'status' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'git status requires {"path": "/path/to/repo"}')
		}
		repo_path := params['path'] or { '.' }
		result := os.execute('cd ${repo_path} && git status --porcelain 2>/dev/null')
		status_str := if result.exit_code == 0 { 'ok' } else { 'error' }
		return json_response(json.encode({
			'tool':   'status'
			'path':   repo_path
			'status': status_str
			'data':   result.output
		}))
	}
	return error_response(400, 'unknown git-mcp tool: "${tool}" — available: repos, status')
}

// --- proof-mcp: Proof verification ---

fn invoke_proof(tool string, args string) http.Response {
	if tool == 'list_backends' {
		mut provers := []string{}
		if os.execute('command -v idris2').exit_code == 0 { provers << 'idris2' }
		if os.execute('command -v z3').exit_code == 0 { provers << 'z3' }
		if os.execute('command -v lean').exit_code == 0 { provers << 'lean' }
		if os.execute('command -v coqc').exit_code == 0 { provers << 'coq' }
		return json_response(json.encode({
			'tool':      'list_backends'
			'available': provers.join(',')
		}))
	}
	if tool == 'check' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'proof check requires {"path": "/path/to/file.idr", "backend": "idris2"}')
		}
		file_path := params['path'] or { '' }
		backend := params['backend'] or { 'idris2' }

		if file_path == '' {
			return error_response(400, 'proof check requires "path" to source file')
		}

		mut cmd := ''
		if backend == 'idris2' { cmd = 'idris2 --check ${file_path} 2>&1' }
		else if backend == 'lean' { cmd = 'lean ${file_path} 2>&1' }
		else { return error_response(400, 'unsupported proof backend: "${backend}"') }

		result := os.execute(cmd)
		status_str := if result.exit_code == 0 { 'verified' } else { 'failed' }
		return json_response(json.encode({
			'tool':      'check'
			'backend':   backend
			'path':      file_path
			'exit_code': result.exit_code.str()
			'output':    result.output
			'status':    status_str
		}))
	}
	return error_response(400, 'unknown proof-mcp tool: "${tool}" — available: list_backends, check')
}

// --- cloud-mcp: cloud provider operations (Cloudflare, etc.) ---

fn invoke_cloud(tool string, args string) http.Response {
	if tool == 'list_providers' {
		mut providers := []string{}
		if os.execute('command -v wrangler').exit_code == 0 { providers << 'cloudflare' }
		if os.execute('command -v aws').exit_code == 0 { providers << 'aws' }
		if os.execute('command -v gcloud').exit_code == 0 { providers << 'gcp' }
		if os.execute('command -v az').exit_code == 0 { providers << 'azure' }
		return json_response(json.encode({
			'tool':      'list_providers'
			'available': providers.join(',')
		}))
	}
	if tool == 'tunnel_status' {
		result := os.execute('pgrep -la cloudflared 2>/dev/null')
		status_str := if result.exit_code == 0 { 'running' } else { 'stopped' }
		return json_response(json.encode({
			'tool':    'tunnel_status'
			'status':  status_str
			'details': result.output.trim_space()
		}))
	}
	if tool == 'dns_lookup' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'dns_lookup requires {"domain": "example.com"}')
		}
		domain := params['domain'] or { '' }
		if domain == '' {
			return error_response(400, 'dns_lookup requires "domain"')
		}
		result := os.execute('dig +short ${domain} 2>&1')
		return json_response(json.encode({
			'tool':   'dns_lookup'
			'domain': domain
			'result': result.output.trim_space()
		}))
	}
	return error_response(400, 'unknown cloud-mcp tool: "${tool}" — available: list_providers, tunnel_status, dns_lookup')
}

// --- k8s-mcp: Kubernetes / container orchestration ---

fn invoke_k8s(tool string, args string) http.Response {
	if tool == 'list_backends' {
		mut backends := []string{}
		if os.execute('command -v kubectl').exit_code == 0 { backends << 'kubectl' }
		if os.execute('command -v podman').exit_code == 0 { backends << 'podman-pod' }
		if os.execute('command -v minikube').exit_code == 0 { backends << 'minikube' }
		if os.execute('command -v kind').exit_code == 0 { backends << 'kind' }
		return json_response(json.encode({
			'tool':      'list_backends'
			'available': backends.join(',')
		}))
	}
	if tool == 'pods' {
		result := os.execute('kubectl get pods --no-headers 2>&1 || podman pod list --format "{{.Name}} {{.Status}}" 2>&1')
		return json_response(json.encode({
			'tool':   'pods'
			'output': result.output.trim_space()
			'status': if result.exit_code == 0 { 'ok' } else { 'error' }
		}))
	}
	if tool == 'namespaces' {
		result := os.execute('kubectl get namespaces --no-headers 2>&1')
		return json_response(json.encode({
			'tool':   'namespaces'
			'output': result.output.trim_space()
			'status': if result.exit_code == 0 { 'ok' } else { 'error' }
		}))
	}
	return error_response(400, 'unknown k8s-mcp tool: "${tool}" — available: list_backends, pods, namespaces')
}

// --- secrets-mcp: secret management (age, sops, pass) ---

fn invoke_secrets(tool string, args string) http.Response {
	if tool == 'list_backends' {
		mut backends := []string{}
		if os.execute('command -v age').exit_code == 0 { backends << 'age' }
		if os.execute('command -v sops').exit_code == 0 { backends << 'sops' }
		if os.execute('command -v pass').exit_code == 0 { backends << 'pass' }
		if os.execute('command -v gpg').exit_code == 0 { backends << 'gpg' }
		return json_response(json.encode({
			'tool':      'list_backends'
			'available': backends.join(',')
		}))
	}
	if tool == 'list_keys' {
		result := os.execute('age-keygen -y ~/.config/sops/age/keys.txt 2>/dev/null || echo "no age keys found"')
		return json_response(json.encode({
			'tool':   'list_keys'
			'output': result.output.trim_space()
		}))
	}
	if tool == 'encrypt' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'encrypt requires {"path": "/path/to/file", "backend": "age"}')
		}
		file_path := params['path'] or { '' }
		backend := params['backend'] or { 'age' }
		if file_path == '' {
			return error_response(400, 'encrypt requires "path"')
		}
		mut cmd := ''
		if backend == 'sops' { cmd = 'sops --encrypt --in-place ${file_path} 2>&1' }
		else if backend == 'age' { cmd = 'age --encrypt --armor -i ~/.config/sops/age/keys.txt ${file_path} 2>&1' }
		else { return error_response(400, 'unsupported secrets backend: "${backend}"') }
		result := os.execute(cmd)
		return json_response(json.encode({
			'tool':      'encrypt'
			'backend':   backend
			'path':      file_path
			'exit_code': result.exit_code.str()
			'status':    if result.exit_code == 0 { 'encrypted' } else { 'failed' }
			'output':    result.output.trim_space()
		}))
	}
	return error_response(400, 'unknown secrets-mcp tool: "${tool}" — available: list_backends, list_keys, encrypt')
}

// --- queues-mcp: message queue operations (Redis pub/sub, etc.) ---

fn invoke_queues(tool string, args string) http.Response {
	if tool == 'list_backends' {
		mut backends := []string{}
		if os.execute('command -v redis-cli').exit_code == 0 { backends << 'redis' }
		if os.execute('command -v rabbitmqctl').exit_code == 0 { backends << 'rabbitmq' }
		if os.execute('command -v nats').exit_code == 0 { backends << 'nats' }
		return json_response(json.encode({
			'tool':      'list_backends'
			'available': backends.join(',')
		}))
	}
	if tool == 'health' {
		result := os.execute('redis-cli --max-time 3 ping 2>&1')
		status_str := if result.output.trim_space() == 'PONG' { 'healthy' } else { 'unreachable' }
		return json_response(json.encode({
			'tool':   'health'
			'status': status_str
			'output': result.output.trim_space()
		}))
	}
	if tool == 'publish' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'publish requires {"channel": "...", "message": "..."}')
		}
		channel := params['channel'] or { '' }
		message := params['message'] or { '' }
		if channel == '' || message == '' {
			return error_response(400, 'publish requires "channel" and "message"')
		}
		result := os.execute('redis-cli PUBLISH ${channel} "${message}" 2>&1')
		return json_response(json.encode({
			'tool':    'publish'
			'channel': channel
			'status':  if result.exit_code == 0 { 'published' } else { 'failed' }
			'output':  result.output.trim_space()
		}))
	}
	return error_response(400, 'unknown queues-mcp tool: "${tool}" — available: list_backends, health, publish')
}

// --- iac-mcp: infrastructure as code (Nickel, Terraform, etc.) ---

fn invoke_iac(tool string, args string) http.Response {
	if tool == 'list_backends' {
		mut backends := []string{}
		if os.execute('command -v nickel').exit_code == 0 { backends << 'nickel' }
		if os.execute('command -v terraform').exit_code == 0 { backends << 'terraform' }
		if os.execute('command -v tofu').exit_code == 0 { backends << 'opentofu' }
		if os.execute('command -v pulumi').exit_code == 0 { backends << 'pulumi' }
		return json_response(json.encode({
			'tool':      'list_backends'
			'available': backends.join(',')
		}))
	}
	if tool == 'validate' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'validate requires {"path": "/path/to/config.ncl", "backend": "nickel"}')
		}
		file_path := params['path'] or { '' }
		backend := params['backend'] or { 'nickel' }
		if file_path == '' {
			return error_response(400, 'validate requires "path"')
		}
		mut cmd := ''
		if backend == 'nickel' { cmd = 'nickel typecheck ${file_path} 2>&1' }
		else if backend == 'terraform' { cmd = 'terraform validate -json 2>&1' }
		else if backend == 'opentofu' { cmd = 'tofu validate -json 2>&1' }
		else { return error_response(400, 'unsupported IaC backend: "${backend}"') }
		result := os.execute(cmd)
		return json_response(json.encode({
			'tool':      'validate'
			'backend':   backend
			'path':      file_path
			'exit_code': result.exit_code.str()
			'status':    if result.exit_code == 0 { 'valid' } else { 'invalid' }
			'output':    result.output.trim_space()
		}))
	}
	if tool == 'eval' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'eval requires {"path": "/path/to/config.ncl"}')
		}
		file_path := params['path'] or { '' }
		if file_path == '' {
			return error_response(400, 'eval requires "path"')
		}
		result := os.execute('nickel export ${file_path} 2>&1')
		return json_response(json.encode({
			'tool':      'eval'
			'path':      file_path
			'exit_code': result.exit_code.str()
			'output':    result.output.trim_space()
		}))
	}
	return error_response(400, 'unknown iac-mcp tool: "${tool}" — available: list_backends, validate, eval')
}

// --- agent-mcp: agentic dispatch and orchestration ---

fn invoke_agent(tool string, args string) http.Response {
	if tool == 'list_agents' {
		// Report known agent types in the ecosystem
		return json_response(json.encode({
			'tool':   'list_agents'
			'agents': 'rhodibot,echidnabot,sustainabot,glambot,seambot,finishbot'
			'source': 'gitbot-fleet'
		}))
	}
	if tool == 'dispatch' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'dispatch requires {"agent": "rhodibot", "task": "..."}')
		}
		agent_name := params['agent'] or { '' }
		task := params['task'] or { '' }
		if agent_name == '' || task == '' {
			return error_response(400, 'dispatch requires "agent" and "task"')
		}
		// Agentic dispatch is recorded but not yet routed to real agents
		return json_response(json.encode({
			'tool':    'dispatch'
			'agent':   agent_name
			'task':    task
			'status':  'queued'
			'message': 'Task queued for ${agent_name}. Agent routing not yet connected.'
		}))
	}
	if tool == 'status' {
		return json_response(json.encode({
			'tool':       'status'
			'fleet_size': '6'
			'connected':  '0'
			'message':    'Fleet agents not yet connected to BoJ dispatch.'
		}))
	}
	return error_response(400, 'unknown agent-mcp tool: "${tool}" — available: list_agents, dispatch, status')
}

// --- nesy-mcp: neurosymbolic reasoning ---

fn invoke_nesy(tool string, args string) http.Response {
	if tool == 'list_backends' {
		mut backends := []string{}
		if os.execute('command -v idris2').exit_code == 0 { backends << 'idris2' }
		if os.execute('command -v swi-prolog').exit_code == 0 || os.execute('command -v swipl').exit_code == 0 { backends << 'prolog' }
		if os.execute('command -v z3').exit_code == 0 { backends << 'z3-smt' }
		return json_response(json.encode({
			'tool':      'list_backends'
			'available': backends.join(',')
		}))
	}
	if tool == 'query' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'query requires {"expression": "...", "backend": "z3-smt"}')
		}
		expression := params['expression'] or { '' }
		backend := params['backend'] or { 'z3-smt' }
		if expression == '' {
			return error_response(400, 'query requires "expression"')
		}
		if backend == 'z3-smt' {
			// Write expression to temp file and run z3
			tmp_path := '/tmp/boj-nesy-query.smt2'
			os.write_file(tmp_path, expression) or {
				return error_response(500, 'failed to write temp file')
			}
			result := os.execute('z3 ${tmp_path} 2>&1')
			return json_response(json.encode({
				'tool':      'query'
				'backend':   backend
				'exit_code': result.exit_code.str()
				'output':    result.output.trim_space()
				'status':    if result.exit_code == 0 { 'completed' } else { 'error' }
			}))
		}
		return error_response(400, 'unsupported nesy backend: "${backend}" — available: z3-smt')
	}
	return error_response(400, 'unknown nesy-mcp tool: "${tool}" — available: list_backends, query')
}

// --- fleet-mcp: gitbot fleet management ---

fn invoke_fleet(tool string, args string) http.Response {
	if tool == 'list_bots' {
		return json_response(json.encode({
			'tool': 'list_bots'
			'bots': 'rhodibot,echidnabot,sustainabot,glambot,seambot,finishbot'
		}))
	}
	if tool == 'scan' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'scan requires {"repo": "owner/repo"}')
		}
		repo := params['repo'] or { '' }
		if repo == '' {
			return error_response(400, 'scan requires "repo"')
		}
		// Check if gh CLI is available for repo scanning
		result := os.execute('gh repo view ${repo} --json name,owner --jq ".owner.login + \\"/\\" + .name" 2>&1')
		return json_response(json.encode({
			'tool':   'scan'
			'repo':   repo
			'status': if result.exit_code == 0 { 'scanned' } else { 'failed' }
			'output': result.output.trim_space()
		}))
	}
	if tool == 'findings' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'findings requires {"repo": "owner/repo"}')
		}
		repo := params['repo'] or { '' }
		if repo == '' {
			return error_response(400, 'findings requires "repo"')
		}
		result := os.execute('gh api repos/${repo}/code-scanning/alerts --jq "length" 2>&1')
		return json_response(json.encode({
			'tool':   'findings'
			'repo':   repo
			'count':  result.output.trim_space()
			'status': if result.exit_code == 0 { 'ok' } else { 'error' }
		}))
	}
	return error_response(400, 'unknown fleet-mcp tool: "${tool}" — available: list_bots, scan, findings')
}

// --- lsp-mcp: Language Server Protocol bridge ---

fn invoke_lsp(tool string, args string) http.Response {
	if tool == 'list_servers' {
		mut servers := []string{}
		if os.execute('command -v v').exit_code == 0 { servers << 'v-analyzer' }
		if os.execute('command -v rust-analyzer').exit_code == 0 { servers << 'rust-analyzer' }
		if os.execute('command -v zls').exit_code == 0 { servers << 'zls' }
		if os.execute('command -v idris2-lsp').exit_code == 0 { servers << 'idris2-lsp' }
		if os.execute('command -v gleam').exit_code == 0 { servers << 'gleam-lsp' }
		if os.execute('command -v elixir-ls').exit_code == 0 { servers << 'elixir-ls' }
		return json_response(json.encode({
			'tool':      'list_servers'
			'available': servers.join(',')
		}))
	}
	if tool == 'diagnostics' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'diagnostics requires {"path": "/path/to/file"}')
		}
		file_path := params['path'] or { '' }
		if file_path == '' {
			return error_response(400, 'diagnostics requires "path"')
		}
		// Use v check for V files, cargo check for Rust, etc.
		ext := if file_path.ends_with('.v') { 'v' }
			else if file_path.ends_with('.rs') { 'rust' }
			else if file_path.ends_with('.zig') { 'zig' }
			else { 'unknown' }
		mut cmd := ''
		if ext == 'v' { cmd = 'v check ${file_path} 2>&1' }
		else if ext == 'rust' { cmd = 'cargo check --message-format=short 2>&1' }
		else if ext == 'zig' { cmd = 'zig build --summary none 2>&1' }
		else { return error_response(400, 'no LSP diagnostics for file type: ${ext}') }
		result := os.execute(cmd)
		return json_response(json.encode({
			'tool':      'diagnostics'
			'path':      file_path
			'language':  ext
			'exit_code': result.exit_code.str()
			'output':    result.output.trim_space()
		}))
	}
	return error_response(400, 'unknown lsp-mcp tool: "${tool}" — available: list_servers, diagnostics')
}

// --- dap-mcp: Debug Adapter Protocol bridge ---

fn invoke_dap(tool string, args string) http.Response {
	if tool == 'list_adapters' {
		mut adapters := []string{}
		if os.execute('command -v lldb-vscode').exit_code == 0 || os.execute('command -v lldb-dap').exit_code == 0 { adapters << 'lldb' }
		if os.execute('command -v gdb').exit_code == 0 { adapters << 'gdb' }
		if os.execute('command -v dlv').exit_code == 0 { adapters << 'delve' }
		return json_response(json.encode({
			'tool':      'list_adapters'
			'available': adapters.join(',')
		}))
	}
	if tool == 'attach' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'attach requires {"pid": "12345", "adapter": "lldb"}')
		}
		pid := params['pid'] or { '' }
		if pid == '' {
			return error_response(400, 'attach requires "pid"')
		}
		// Verify the PID exists
		result := os.execute('kill -0 ${pid} 2>&1')
		return json_response(json.encode({
			'tool':   'attach'
			'pid':    pid
			'status': if result.exit_code == 0 { 'process_found' } else { 'process_not_found' }
			'note':   'Full DAP session management not yet implemented. Process existence verified.'
		}))
	}
	return error_response(400, 'unknown dap-mcp tool: "${tool}" — available: list_adapters, attach')
}

// --- bsp-mcp: Build Server Protocol bridge ---

fn invoke_bsp(tool string, args string) http.Response {
	if tool == 'list_backends' {
		mut backends := []string{}
		if os.execute('command -v just').exit_code == 0 { backends << 'just' }
		if os.execute('command -v cargo').exit_code == 0 { backends << 'cargo' }
		if os.execute('command -v zig').exit_code == 0 { backends << 'zig-build' }
		if os.execute('command -v deno').exit_code == 0 { backends << 'deno' }
		if os.execute('command -v mix').exit_code == 0 { backends << 'mix' }
		if os.execute('command -v gleam').exit_code == 0 { backends << 'gleam' }
		return json_response(json.encode({
			'tool':      'list_backends'
			'available': backends.join(',')
		}))
	}
	if tool == 'build' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'build requires {"path": "/path/to/project", "backend": "just"}')
		}
		project_path := params['path'] or { '' }
		backend := params['backend'] or { 'just' }
		if project_path == '' {
			return error_response(400, 'build requires "path"')
		}
		mut cmd := ''
		if backend == 'just' { cmd = 'cd ${project_path} && just build 2>&1' }
		else if backend == 'cargo' { cmd = 'cd ${project_path} && cargo build 2>&1' }
		else if backend == 'zig-build' { cmd = 'cd ${project_path} && zig build 2>&1' }
		else if backend == 'deno' { cmd = 'cd ${project_path} && deno task build 2>&1' }
		else { return error_response(400, 'unsupported BSP backend: "${backend}"') }
		result := os.execute(cmd)
		return json_response(json.encode({
			'tool':      'build'
			'backend':   backend
			'path':      project_path
			'exit_code': result.exit_code.str()
			'status':    if result.exit_code == 0 { 'success' } else { 'failed' }
			'output':    result.output.trim_space()
		}))
	}
	if tool == 'targets' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'targets requires {"path": "/path/to/project"}')
		}
		project_path := params['path'] or { '' }
		if project_path == '' {
			return error_response(400, 'targets requires "path"')
		}
		result := os.execute('cd ${project_path} && just --list --unsorted 2>&1 || cargo metadata --format-version=1 --no-deps 2>&1 | head -5')
		return json_response(json.encode({
			'tool':   'targets'
			'path':   project_path
			'output': result.output.trim_space()
		}))
	}
	return error_response(400, 'unknown bsp-mcp tool: "${tool}" — available: list_backends, build, targets')
}

// --- feedback-mcp: feedback-o-tron feedback collection and sentiment tracking ---
// Wired to Zig FFI (fb_register, fb_submit, etc.) for real state-machine execution.
// This is the self-dogfooding loop: BoJ collects feedback on itself via its own
// feedback cartridge.

// Channel name → FFI channel type mapping
fn fb_channel_type(name string) int {
	return match name {
		'web_form' { 1 }
		'api' { 2 }
		'email' { 3 }
		'irc' { 4 }
		'mastodon' { 5 }
		'gitea' { 6 }
		else { 99 } // custom
	}
}

// Sentiment name → FFI sentiment value mapping
fn fb_sentiment_val(name string) int {
	return match name {
		'positive' { 1 }
		'negative' { -1 }
		'neutral' { 0 }
		else { -99 } // unclassified
	}
}

// State int → label
fn fb_state_label(state int) string {
	return match state {
		0 { 'inactive' }
		1 { 'channel_registered' }
		2 { 'collecting' }
		3 { 'processing' }
		4 { 'error' }
		else { 'unknown' }
	}
}

fn invoke_feedback(tool string, args string) http.Response {
	if tool == 'list_channels' {
		return json_response(json.encode({
			'tool':      'list_channels'
			'available': 'web_form,api,email,irc,mastodon,gitea,custom'
		}))
	}
	if tool == 'open_channel' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'open_channel requires {"channel": "api"}')
		}
		channel := params['channel'] or { '' }
		if channel == '' {
			return error_response(400, 'open_channel requires "channel"')
		}
		slot := C.fb_register(fb_channel_type(channel))
		if slot < 0 {
			return error_response(503, 'no feedback channel slots available (max 8)')
		}
		return json_response(json.encode({
			'tool':    'open_channel'
			'channel': channel
			'slot':    '${slot}'
			'state':   'channel_registered'
		}))
	}
	if tool == 'submit' {
		params := json.decode(map[string]string, args) or {
			return error_response(400, 'submit requires {"slot": "0", "sentiment": "positive|neutral|negative"}')
		}
		slot_str := params['slot'] or { '0' }
		sentiment := params['sentiment'] or { 'neutral' }
		slot := slot_str.int()
		result := C.fb_submit(slot, fb_sentiment_val(sentiment))
		if result == -1 {
			return error_response(400, 'invalid slot ${slot_str}')
		}
		if result == -2 {
			return error_response(400, 'channel not in collecting state')
		}
		return json_response(json.encode({
			'tool':      'submit'
			'slot':      slot_str
			'sentiment': sentiment
			'count':     '${result}'
			'status':    'recorded'
		}))
	}
	if tool == 'summary' {
		// Query all 8 possible slots
		mut active_channels := []map[string]string{}
		for i in 0 .. 8 {
			state := C.fb_state(i)
			if state > 0 { // not inactive
				active_channels << {
					'slot':     '${i}'
					'state':    fb_state_label(state)
					'total':    '${C.fb_count(i)}'
					'positive': '${C.fb_positive_count(i)}'
					'negative': '${C.fb_negative_count(i)}'
					'neutral':  '${C.fb_neutral_count(i)}'
				}
			}
		}
		return json_response(json.encode({
			'tool':             'summary'
			'active_channels':  '${active_channels.len}'
			'status':           'ok'
		}))
	}
	if tool == 'status' {
		return json_response(json.encode({
			'tool':    'status'
			'state':   'active'
			'message': 'feedback-o-tron is running. FFI state machine wired.'
		}))
	}
	return error_response(400, 'unknown feedback-mcp tool: "${tool}" — available: list_channels, open_channel, submit, summary, status')
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
	domains := [CapabilityDomain.cloud, .container, .database, .k8s, .git, .secrets, .queues, .iac, .observe, .ssg, .proof, .fleet_dom, .nesy_dom, .feedback]
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
					'endpoint': 'http://localhost:7700/order'
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
// Umoja Federation REST handlers
// ═══════════════════════════════════════════════════════════════════════

fn handle_umoja_status(app &BojApp) http.Response {
	return json_response(json.encode({
		'node_id':         app.node_id
		'region':          app.region
		'transport':       if C.umoja_transport_mode() == 1 { 'quic' } else { 'udp' }
		'bound':           (int(C.umoja_is_bound())).str()
		'peers':           (int(C.umoja_peer_count())).str()
		'gossip_rounds':   (int(C.umoja_gossip_round_count())).str()
		'packets_sent':    (int(C.umoja_packets_sent())).str()
		'packets_received': (int(C.umoja_packets_received())).str()
	}))
}

fn handle_umoja_peers() http.Response {
	peer_count := int(C.umoja_peer_count())
	return json_response(json.encode({
		'count': peer_count.str()
	}))
}

fn handle_umoja_add_peer(body string) http.Response {
	params := json.decode(map[string]string, body) or {
		return error_response(400, 'requires {"host": "::1", "port": "9999"}')
	}
	host := params['host'] or { '' }
	port_str := params['port'] or { '9999' }
	if host == '' {
		return error_response(400, 'host is required')
	}
	port := u16(port_str.int())
	result := C.umoja_add_peer(host.str, host.len, port)
	if result < 0 {
		return error_response(503, 'failed to add peer')
	}
	return json_response(json.encode({
		'status': 'added'
		'host':   host
		'port':   port_str
		'index':  result.str()
	}))
}

// ═══════════════════════════════════════════════════════════════════════
// Coprocessor Dispatch REST handlers
// ═══════════════════════════════════════════════════════════════════════

fn accel_kind_name(kind u8) string {
	return match kind {
		0 { 'cpu' }
		1 { 'cuda' }
		2 { 'rocm' }
		3 { 'metal' }
		4 { 'tpu' }
		5 { 'fpga' }
		else { 'unknown' }
	}
}

fn handle_coprocessor_status() http.Response {
	dev_count := int(C.boj_coprocessor_device_count())
	mut device_list := []string{}
	for i in 0 .. dev_count {
		kind := C.boj_coprocessor_device_kind(usize(i))
		status := C.boj_coprocessor_device_status(usize(i))
		dispatches := C.boj_coprocessor_device_dispatches(usize(i))
		device_list << '{"kind":"${accel_kind_name(kind)}","status":${status},"dispatches":${dispatches}}'
	}
	affinities := int(C.boj_coprocessor_affinity_count())
	has_cuda := int(C.boj_coprocessor_has_accelerator(1))
	has_rocm := int(C.boj_coprocessor_has_accelerator(2))
	has_tpu := int(C.boj_coprocessor_has_accelerator(4))
	has_fpga := int(C.boj_coprocessor_has_accelerator(5))
	body := '{"devices":[${device_list.join(",")}],"affinities":${affinities},"accelerators":{"cuda":${has_cuda},"rocm":${has_rocm},"tpu":${has_tpu},"fpga":${has_fpga}}}'
	return json_response(body)
}

fn handle_coprocessor_select(body string) http.Response {
	params := json.decode(map[string]string, body) or {
		return error_response(400, 'requires {"cartridge": "name"}')
	}
	name := params['cartridge'] or { '' }
	if name == '' {
		return error_response(400, 'cartridge name is required')
	}
	mut fallback := u8(0)
	selected := C.boj_coprocessor_select_by_name(name.str, name.len, &fallback)
	return json_response(json.encode({
		'cartridge': name
		'device':    accel_kind_name(selected)
		'fallback':  if fallback == 1 { 'true' } else { 'false' }
	}))
}

// ═══════════════════════════════════════════════════════════════════════
// SLA Monitoring REST handlers
// ═══════════════════════════════════════════════════════════════════════

fn handle_sla_status() http.Response {
	total_req := C.boj_sla_total_requests()
	total_err := C.boj_sla_total_errors()
	tracked := int(C.boj_sla_cartridge_count())
	return json_response('{"total_requests":${total_req},"total_errors":${total_err},"cartridges_tracked":${tracked}}')
}

// ═══════════════════════════════════════════════════════════════════════
// Community Submission REST handlers
// ═══════════════════════════════════════════════════════════════════════

fn review_status_name(status u8) string {
	return match status {
		0 { 'submitted' }
		1 { 'under_review' }
		2 { 'approved' }
		3 { 'rejected' }
		4 { 'suspended' }
		else { 'unknown' }
	}
}

fn handle_community_list() http.Response {
	total := int(C.boj_community_count())
	approved := int(C.boj_community_count_approved())
	pending := int(C.boj_community_count_pending())
	return json_response('{"total":${total},"approved":${approved},"pending":${pending}}')
}

fn handle_community_submit(body string) http.Response {
	params := json.decode(map[string]string, body) or {
		return error_response(400, 'requires {"name","author","description","hash"}')
	}
	name := params['name'] or { '' }
	author := params['author'] or { '' }
	desc := params['description'] or { '' }
	hash := params['hash'] or { '' }
	if name == '' || author == '' || hash == '' {
		return error_response(400, 'name, author, and hash are required')
	}
	result := C.boj_community_submit(name.str, name.len, author.str, author.len, desc.str, desc.len, hash.str, hash.len)
	if result < 0 {
		err_msg := match result {
			-1 { 'max submissions reached' }
			-2 { 'invalid name' }
			-3 { 'hash must be 64 hex chars' }
			-4 { 'duplicate cartridge name' }
			else { 'submission failed' }
		}
		return error_response(409, err_msg)
	}
	return json_response(json.encode({
		'status':  'submitted'
		'name':    name
		'index':   result.str()
	}))
}

// ═══════════════════════════════════════════════════════════════════════
// Auto-SDP REST handlers
// ═══════════════════════════════════════════════════════════════════════

fn handle_sdp_status() http.Response {
	peers := int(C.boj_sdp_peer_count())
	bans := int(C.boj_sdp_ban_count())
	return json_response('{"authorised_peers":${peers},"active_bans":${bans}}')
}

// ═══════════════════════════════════════════════════════════════════════
// MCP Stdio Bridge (JSON-RPC 2.0 over stdin/stdout)
// ═══════════════════════════════════════════════════════════════════════
//
// Usage: boj-server --mcp
//
// Speaks the Model Context Protocol so AI tools (Claude Code, Cursor, etc.)
// can consume BoJ cartridges natively.  Each mounted cartridge's tools
// become MCP tools.  The bridge reads JSON-RPC from stdin and writes
// responses to stdout — no HTTP server needed.
//
// Add to claude_desktop_config.json:
//   { "mcpServers": { "boj": { "command": "/path/to/boj-server", "args": ["--mcp"] } } }

struct McpRequest {
	jsonrpc string
	method  string
	id      int
	params  map[string]string
}

fn mcp_response(id int, result string) string {
	return '{"jsonrpc":"2.0","id":${id},"result":${result}}'
}

fn mcp_error(id int, code int, message string) string {
	return '{"jsonrpc":"2.0","id":${id},"error":{"code":${code},"message":"${message}"}}'
}

fn mcp_tools_list(app &BojApp) string {
	// Build tool list from all registered cartridges
	mut tools := []string{}
	for c in app.cartridges {
		cart_tools := mcp_cartridge_tools(c.name)
		for t in cart_tools {
			tools << t
		}
	}
	return '[${tools.join(",")}]'
}

fn mcp_cartridge_tools(cname string) []string {
	// Return MCP tool definitions for a cartridge.
	// Each tool is a JSON object with name, description, and inputSchema.
	base := cname.replace('-mcp', '')
	return [
		'{"name":"${cname}/status","description":"Get ${base} cartridge status","inputSchema":{"type":"object","properties":{}}}',
	]
}

fn mcp_handle_tool_call(app &BojApp, tool_name string, args string) string {
	// Parse tool name as "cartridge-name/tool"
	parts := tool_name.split('/')
	if parts.len != 2 {
		return '{"content":[{"type":"text","text":"unknown tool: ${tool_name}"}],"isError":true}'
	}
	cname := parts[0]
	tool := parts[1]

	// Find and mount the cartridge if needed
	for i, c in app.cartridges {
		if c.name == cname {
			if C.boj_catalogue_is_mounted(usize(i)) != 1 {
				C.boj_catalogue_mount(usize(i))
			}
			break
		}
	}

	// Route to the cartridge invoke handler
	invoke_args := if args.len > 0 { args } else { '{}' }
	resp := handle_cartridge_invoke(app, cname, '{"tool":"${tool}","args":"${invoke_args}"}')
	body := resp.body
	return '{"content":[{"type":"text","text":${json.encode(body)}}]}'
}

fn run_mcp_stdio() {
	// Initialise the catalogue (same as server mode)
	mut app := BojApp.new()
	app.init_catalogue() or {
		eprintln('FATAL: ${err.msg()}')
		exit(1)
	}
	defer { C.boj_catalogue_deinit() }

	// Initialise feedback FFI
	C.boj_cartridge_init()

	// Register all 18 built-in cartridges
	app.register_builtin_cartridges() or {
		eprintln('FATAL: ${err.msg()}')
		exit(1)
	}

	// Mount all ready cartridges
	count := int(C.boj_catalogue_count())
	for i in 0 .. count {
		C.boj_catalogue_mount(usize(i))
	}

	app_ref := &app

	// MCP stdio loop: read JSON-RPC from stdin, write to stdout
	for {
		line := os.get_raw_line()
		if line.len == 0 {
			break // EOF
		}
		trimmed := line.trim_space()
		if trimmed.len == 0 {
			continue
		}

		// Parse JSON-RPC request
		req := json.decode(McpRequest, trimmed) or {
			println(mcp_error(0, -32700, 'parse error'))
			continue
		}

		// Dispatch by method
		response := match req.method {
			'initialize' {
				mcp_response(req.id, '{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"boj-server","version":"0.1.0"}}')
			}
			'notifications/initialized' {
				// Client acknowledgment — no response needed
				''
			}
			'tools/list' {
				tools := mcp_tools_list(app_ref)
				mcp_response(req.id, '{"tools":${tools}}')
			}
			'tools/call' {
				tool_name := req.params['name'] or { '' }
				tool_args := req.params['arguments'] or { '{}' }
				result := mcp_handle_tool_call(app_ref, tool_name, tool_args)
				mcp_response(req.id, result)
			}
			'ping' {
				mcp_response(req.id, '{}')
			}
			else {
				mcp_error(req.id, -32601, 'method not found: ${req.method}')
			}
		}

		if response.len > 0 {
			println(response)
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════

fn main() {
	// MCP stdio mode: boj-server --mcp
	// Speaks JSON-RPC 2.0 over stdin/stdout (Model Context Protocol).
	// This is the native MCP bridge — AI tools consume this directly.
	if '--mcp' in os.args {
		run_mcp_stdio()
		return
	}

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

	// Initialise Umoja federation
	C.boj_federation_init()
	fed_port := u16((os.getenv_opt('BOJ_FEDERATION_PORT') or { '9999' }).int())
	node_id := app.node_id
	C.umoja_set_node_id(node_id.str, node_id.len)
	use_quic := os.getenv_opt('BOJ_QUIC') or { '1' }
	if use_quic == '1' {
		fed_result := C.umoja_bind_quic(fed_port)
		if fed_result == 0 {
			println('Federation: QUIC-first on :${fed_port} (UDP fallback)')
		} else {
			println('Federation: bind failed on :${fed_port} (running without federation)')
		}
	} else {
		fed_result := C.umoja_bind(fed_port)
		if fed_result == 0 {
			println('Federation: UDP on :${fed_port}')
		} else {
			println('Federation: bind failed on :${fed_port} (running without federation)')
		}
	}

	// Initialise coprocessor dispatch
	C.boj_coprocessor_init()
	coproc_devs := int(C.boj_coprocessor_device_count())
	println('Coprocessor: ${coproc_devs} device(s) detected')

	// Initialise SLA monitoring
	C.boj_sla_init()
	println('SLA: monitoring initialised')

	// Initialise community cartridge registry
	C.boj_community_init()
	println('Community: Ayo tier submissions ready')

	// Initialise Auto-SDP perimeter
	C.boj_sdp_init()
	println('SDP: perimeter active (open mode for seed bootstrapping)')

	// Initialise feedback-o-tron (self-dogfooding: BoJ collects feedback on itself)
	C.boj_cartridge_init()
	println('Feedback: feedback-o-tron initialised')

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

	// Configurable ports via env (defaults: 7700/7701/7702)
	rest_port := os.getenv_opt('BOJ_REST_PORT') or { '7700' }
	grpc_port := os.getenv_opt('BOJ_GRPC_PORT') or { '7701' }
	graphql_port := os.getenv_opt('BOJ_GRAPHQL_PORT') or { '7702' }

	// Pre-bind listeners (V 0.5.0 http.Server auto-bind is broken;
	// pre-binding with net.listen_tcp works reliably).
	rest_listener := net.listen_tcp(.ip, '0.0.0.0:${rest_port}') or {
		eprintln('FATAL: cannot bind REST on :${rest_port}: ${err}')
		exit(1)
	}
	println('Starting REST  on :${rest_port}')
	mut rest_srv := &http.Server{
		listener: rest_listener
		handler: RestHandler{app: app_ref}
		show_startup_message: false
	}
	spawn rest_srv.listen_and_serve()

	gql_listener := net.listen_tcp(.ip, '0.0.0.0:${graphql_port}') or {
		eprintln('FATAL: cannot bind GraphQL on :${graphql_port}: ${err}')
		exit(1)
	}
	println('Starting GraphQL on :${graphql_port}')
	mut gql_srv := &http.Server{
		listener: gql_listener
		handler: GraphQLHandler{app: app_ref}
		show_startup_message: false
	}
	spawn gql_srv.listen_and_serve()

	// gRPC-compat — JSON-over-HTTP until vlib gains protobuf support.
	grpc_listener := net.listen_tcp(.ip, '0.0.0.0:${grpc_port}') or {
		eprintln('FATAL: cannot bind gRPC on :${grpc_port}: ${err}')
		exit(1)
	}
	println('Starting gRPC-compat on :${grpc_port} (JSON-over-HTTP, service/method paths)')
	mut grpc_srv := &http.Server{
		listener: grpc_listener
		handler: GrpcHandler{app: app_ref}
		show_startup_message: false
	}
	spawn grpc_srv.listen_and_serve()

	println('')
	println('BoJ Server ready. Endpoints:')
	println('  REST:    http://localhost:${rest_port}/status')
	println('  gRPC:    grpc://localhost:${grpc_port} (JSON-compat)')
	println('  GraphQL: http://localhost:${graphql_port}/graphql')
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
