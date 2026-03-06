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
import os.cmdline
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

struct BojApp {
mut:
	cartridges []CartridgeInfo
	start_time time.Time
	node_id    string
	region     string
}

fn BojApp.new() BojApp {
	return BojApp{
		cartridges: []CartridgeInfo{}
		start_time: time.now()
		node_id: os.getenv_opt('BOJ_NODE_ID') or { 'local-0' }
		region: os.getenv_opt('BOJ_REGION') or { 'local' }
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
		status: .ok
		header: http.new_header_from_map({
			.content_type: 'application/json; charset=utf-8'
		})
		body: data
	}
}

fn error_response(status http.Status, message string) http.Response {
	body := json.encode({
		'error': message
	})
	return http.Response{
		status: status
		header: http.new_header_from_map({
			.content_type: 'application/json; charset=utf-8'
		})
		body: body
	}
}

fn rest_handler(mut app BojApp) fn (http.Request) http.Response {
	return fn [app] (req http.Request) http.Response {
		path := req.url.path

		match path {
			'/health' {
				return json_response('{"status":"ok"}')
			}
			'/status' {
				return json_response(json.encode(app.build_status()))
			}
			'/menu' {
				return json_response(json.encode(app.build_menu()))
			}
			'/order' {
				if req.method != .post {
					return error_response(.method_not_allowed, 'POST required')
				}
				order := json.decode(OrderRequest, req.body) or {
					return error_response(.bad_request, 'invalid order JSON: ${err.msg()}')
				}
				return handle_order(mut app, order)
			}
			else {
				return error_response(.not_found, 'unknown endpoint: ${path}')
			}
		}
	}
}

fn handle_order(mut app BojApp, order OrderRequest) http.Response {
	session_id := '${time.now().unix()}:${order.requested_by}'
	mut mounted := []string{}
	mut failed := []OrderFailure{}
	mut endpoints := []EndpointInfo{}

	for name in order.cartridges {
		app.mount_cartridge(name) or {
			failed << OrderFailure{
				cartridge: name
				reason: err.msg()
			}
			continue
		}
		mounted << name
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
// GraphQL Server (port 9002)
// ═══════════════════════════════════════════════════════════════════════

fn graphql_handler(app &BojApp) fn (http.Request) http.Response {
	return fn [app] (req http.Request) http.Response {
		// Minimal GraphQL introspection + query support
		if req.method != .post {
			return error_response(.method_not_allowed, 'POST required for GraphQL')
		}

		body := json.decode(map[string]string, req.body) or {
			return error_response(.bad_request, 'invalid GraphQL request')
		}
		query := body['query'] or { '' }

		if query.contains('__schema') || query.contains('__type') {
			return json_response(graphql_schema())
		}

		if query.contains('status') {
			return json_response(json.encode({
				'data': {
					'status': json.encode(app.build_status())
				}
			}))
		}

		if query.contains('menu') {
			return json_response(json.encode({
				'data': {
					'menu': json.encode(app.build_menu())
				}
			}))
		}

		return error_response(.bad_request, 'unsupported query')
	}
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

	// REST server on port 9000
	println('Starting REST  on :9000')
	spawn http.Server{
		addr: ':9000'
		handler: rest_handler(mut app)
	}.listen_and_serve()

	// GraphQL server on port 9002
	println('Starting GraphQL on :9002')
	spawn http.Server{
		addr: ':9002'
		handler: graphql_handler(&app)
	}.listen_and_serve()

	// gRPC on port 9001 — V-lang has no native gRPC library yet.
	// For now, serve a JSON-over-HTTP/2 endpoint that mirrors the gRPC contract.
	// This will be replaced with proper gRPC when vlib gains protobuf support.
	println('Starting gRPC-compat on :9001 (JSON-over-HTTP/2 until vlib gains protobuf)')
	spawn http.Server{
		addr: ':9001'
		handler: rest_handler(mut app)
	}.listen_and_serve()

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
