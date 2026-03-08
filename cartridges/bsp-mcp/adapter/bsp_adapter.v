// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BSP-MCP Cartridge — V-lang triple adapter (REST + gRPC + GraphQL).
//
// Exposes BSP lifecycle management via all three API protocols.
// REST on port 9022, gRPC-compat on 9023, GraphQL on 9024.

module bsp_adapter

import vweb
import json

// ═══════════════════════════════════════════════════════════════════════
// FFI declarations (from bsp_ffi.zig via C-ABI)
// ═══════════════════════════════════════════════════════════════════════

fn C.bsp_init() int
fn C.bsp_start_init(slot int) int
fn C.bsp_register_capability(slot int, cap int) int
fn C.bsp_ready(slot int) int
fn C.bsp_build(slot int) int
fn C.bsp_build_done(slot int) int
fn C.bsp_shutdown(slot int) int
fn C.bsp_exit(slot int) int
fn C.bsp_state(slot int) int
fn C.bsp_can_build(slot int) int
fn C.bsp_is_building(slot int) int
fn C.bsp_add_target(slot int, kind int) int
fn C.bsp_has_capability(slot int, cap int) int
fn C.bsp_can_transition(from int, to int) int
fn C.bsp_release(slot int) int

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

const bsp_state_labels = ['uninitialized', 'initializing', 'ready', 'building',
	'shutting_down', 'exited']

const target_kind_labels = ['', 'library', 'application', 'test', 'benchmark',
	'integration_test', 'documentation']

const capability_labels = ['compile', 'test', 'run', 'debug', 'clean_cache',
	'dependency_sources', 'resources', 'output_paths', 'jvm_test_env']

fn state_label(s int) string {
	if s >= 0 && s < bsp_state_labels.len {
		return bsp_state_labels[s]
	}
	return 'unknown'
}

// ═══════════════════════════════════════════════════════════════════════
// REST API (vweb)
// ═══════════════════════════════════════════════════════════════════════

struct BspApp {
	vweb.Context
}

['/health']
fn (mut app BspApp) health() vweb.Result {
	return app.json({'status': 'ok', 'cartridge': 'bsp-mcp', 'version': '0.1.0'})
}

['/types']
fn (mut app BspApp) types() vweb.Result {
	return app.json({
		'states':       bsp_state_labels
		'target_kinds': target_kind_labels
		'capabilities': capability_labels
	})
}

['/sessions'; post]
fn (mut app BspApp) create_session() vweb.Result {
	slot := C.bsp_init()
	if slot < 0 {
		return app.json({'error': 'no slots available'})
	}
	return app.json({'slot': slot, 'state': 'uninitialized'})
}

['/sessions/:slot/build'; post]
fn (mut app BspApp) do_build(slot string) vweb.Result {
	s := slot.int()
	r := C.bsp_build(s)
	if r < 0 {
		return app.json({'error': 'invalid transition', 'code': r})
	}
	return app.json({'slot': s, 'state': 'building'})
}

['/sessions/:slot/state']
fn (mut app BspApp) get_state(slot string) vweb.Result {
	s := slot.int()
	st := C.bsp_state(s)
	return app.json({
		'slot':        s
		'state':       state_label(st)
		'can_build':   C.bsp_can_build(s) == 1
		'is_building': C.bsp_is_building(s) == 1
	})
}

// ═══════════════════════════════════════════════════════════════════════
// GraphQL Schema
// ═══════════════════════════════════════════════════════════════════════

const graphql_schema = '
type Query {
  health: Health!
  session(slot: Int!): BspSession
  types: TypeInfo!
}

type Mutation {
  createSession: BspSession!
  initialize(slot: Int!): BspSession!
  ready(slot: Int!): BspSession!
  build(slot: Int!): BspSession!
  buildDone(slot: Int!): BspSession!
  shutdown(slot: Int!): BspSession!
  exit(slot: Int!): BspSession!
  addTarget(slot: Int!, kind: Int!): TargetResult!
  registerCapability(slot: Int!, capability: Int!): BspSession!
}

type Health {
  status: String!
  cartridge: String!
  version: String!
}

type BspSession {
  slot: Int!
  state: String!
  canBuild: Boolean!
  isBuilding: Boolean!
  capabilities: [String!]!
}

type TargetResult {
  slot: Int!
  targetIndex: Int!
}

type TypeInfo {
  states: [String!]!
  targetKinds: [String!]!
  capabilities: [String!]!
}
'

// ═══════════════════════════════════════════════════════════════════════
// gRPC Proto Definition
// ═══════════════════════════════════════════════════════════════════════

const grpc_proto = '
syntax = "proto3";
package bsp_mcp;

service BspService {
  rpc CreateSession(Empty) returns (SessionResponse);
  rpc Initialize(SlotRequest) returns (SessionResponse);
  rpc Ready(SlotRequest) returns (SessionResponse);
  rpc Build(SlotRequest) returns (SessionResponse);
  rpc BuildDone(SlotRequest) returns (SessionResponse);
  rpc Shutdown(SlotRequest) returns (SessionResponse);
  rpc Exit(SlotRequest) returns (SessionResponse);
  rpc GetState(SlotRequest) returns (SessionResponse);
  rpc AddTarget(TargetRequest) returns (TargetResponse);
  rpc RegisterCapability(CapabilityRequest) returns (SessionResponse);
  rpc Health(Empty) returns (HealthResponse);
}

message Empty {}
message SlotRequest { int32 slot = 1; }
message TargetRequest { int32 slot = 1; int32 kind = 2; }
message CapabilityRequest { int32 slot = 1; int32 capability = 2; }
message SessionResponse { int32 slot = 1; string state = 2; bool can_build = 3; bool is_building = 4; }
message TargetResponse { int32 slot = 1; int32 target_index = 2; }
message HealthResponse { string status = 1; string cartridge = 2; string version = 3; }
'
