// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// LSP-MCP Cartridge — V-lang triple adapter (REST + gRPC + GraphQL).
//
// Exposes LSP lifecycle management via all three API protocols.
// REST on port 9016, gRPC-compat on 9017, GraphQL on 9018.

module lsp_adapter

import vweb
import json

// ═══════════════════════════════════════════════════════════════════════
// FFI declarations (from lsp_ffi.zig via C-ABI)
// ═══════════════════════════════════════════════════════════════════════

fn C.lsp_init() int
fn C.lsp_start_init(slot int) int
fn C.lsp_register_capability(slot int, cap int) int
fn C.lsp_initialized(slot int) int
fn C.lsp_shutdown(slot int) int
fn C.lsp_exit(slot int) int
fn C.lsp_state(slot int) int
fn C.lsp_has_capability(slot int, cap int) int
fn C.lsp_can_transition(from int, to int) int
fn C.lsp_release(slot int) int

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

const lsp_state_labels = ['uninitialized', 'initializing', 'running', 'shutting_down', 'exited']

const capability_labels = ['text_doc_sync', 'completion', 'hover', 'signature_help',
	'definition', 'references', 'document_symbol', 'code_action', 'diagnostics',
	'formatting', 'rename', 'semantic_tokens']

fn state_label(s int) string {
	if s >= 0 && s < lsp_state_labels.len {
		return lsp_state_labels[s]
	}
	return 'unknown'
}

// ═══════════════════════════════════════════════════════════════════════
// REST API (vweb)
// ═══════════════════════════════════════════════════════════════════════

struct LspApp {
	vweb.Context
}

['/health']
fn (mut app LspApp) health() vweb.Result {
	return app.json({'status': 'ok', 'cartridge': 'lsp-mcp', 'version': '0.1.0'})
}

['/types']
fn (mut app LspApp) types() vweb.Result {
	return app.json({
		'states':       lsp_state_labels
		'capabilities': capability_labels
	})
}

['/sessions'; post]
fn (mut app LspApp) create_session() vweb.Result {
	slot := C.lsp_init()
	if slot < 0 {
		return app.json({'error': 'no slots available'})
	}
	return app.json({'slot': slot, 'state': 'uninitialized'})
}

['/sessions/:slot/initialize'; post]
fn (mut app LspApp) initialize(slot string) vweb.Result {
	s := slot.int()
	r := C.lsp_start_init(s)
	if r < 0 {
		return app.json({'error': 'invalid transition', 'code': r})
	}
	return app.json({'slot': s, 'state': 'initializing'})
}

['/sessions/:slot/initialized'; post]
fn (mut app LspApp) initialized(slot string) vweb.Result {
	s := slot.int()
	r := C.lsp_initialized(s)
	if r < 0 {
		return app.json({'error': 'invalid transition', 'code': r})
	}
	return app.json({'slot': s, 'state': 'running'})
}

['/sessions/:slot/shutdown'; post]
fn (mut app LspApp) shutdown(slot string) vweb.Result {
	s := slot.int()
	r := C.lsp_shutdown(s)
	if r < 0 {
		return app.json({'error': 'invalid transition', 'code': r})
	}
	return app.json({'slot': s, 'state': 'shutting_down'})
}

['/sessions/:slot/state']
fn (mut app LspApp) get_state(slot string) vweb.Result {
	s := slot.int()
	st := C.lsp_state(s)
	return app.json({'slot': s, 'state': state_label(st)})
}

// ═══════════════════════════════════════════════════════════════════════
// GraphQL Schema
// ═══════════════════════════════════════════════════════════════════════

const graphql_schema = '
type Query {
  health: Health!
  session(slot: Int!): Session
  types: TypeInfo!
}

type Mutation {
  createSession: Session!
  initialize(slot: Int!): Session!
  initialized(slot: Int!): Session!
  shutdown(slot: Int!): Session!
  exit(slot: Int!): Session!
  registerCapability(slot: Int!, capability: Int!): Session!
}

type Health {
  status: String!
  cartridge: String!
  version: String!
}

type Session {
  slot: Int!
  state: String!
  capabilities: [String!]!
}

type TypeInfo {
  states: [String!]!
  capabilities: [String!]!
}
'

// ═══════════════════════════════════════════════════════════════════════
// gRPC Proto Definition
// ═══════════════════════════════════════════════════════════════════════

const grpc_proto = '
syntax = "proto3";
package lsp_mcp;

service LspService {
  rpc CreateSession(Empty) returns (SessionResponse);
  rpc Initialize(SlotRequest) returns (SessionResponse);
  rpc Initialized(SlotRequest) returns (SessionResponse);
  rpc Shutdown(SlotRequest) returns (SessionResponse);
  rpc Exit(SlotRequest) returns (SessionResponse);
  rpc GetState(SlotRequest) returns (SessionResponse);
  rpc RegisterCapability(CapabilityRequest) returns (SessionResponse);
  rpc Health(Empty) returns (HealthResponse);
}

message Empty {}
message SlotRequest { int32 slot = 1; }
message CapabilityRequest { int32 slot = 1; int32 capability = 2; }
message SessionResponse { int32 slot = 1; string state = 2; repeated string capabilities = 3; }
message HealthResponse { string status = 1; string cartridge = 2; string version = 3; }
'
