// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// DAP-MCP Cartridge — V-lang triple adapter (REST + gRPC + GraphQL).
//
// Exposes DAP lifecycle management via all three API protocols.
// REST on port 9019, gRPC-compat on 9020, GraphQL on 9021.

module dap_adapter

import vweb
import json

// ═══════════════════════════════════════════════════════════════════════
// FFI declarations (from dap_ffi.zig via C-ABI)
// ═══════════════════════════════════════════════════════════════════════

fn C.dap_init() int
fn C.dap_launch(slot int) int
fn C.dap_configure(slot int) int
fn C.dap_continue(slot int) int
fn C.dap_stopped(slot int, reason int) int
fn C.dap_terminate(slot int) int
fn C.dap_disconnect(slot int) int
fn C.dap_state(slot int) int
fn C.dap_can_inspect(slot int) int
fn C.dap_can_set_breakpoints(slot int) int
fn C.dap_add_breakpoint(slot int, kind int) int
fn C.dap_can_transition(from int, to int) int
fn C.dap_release(slot int) int

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

const dap_state_labels = ['not_started', 'launched', 'configured', 'running',
	'stopped', 'terminated', 'disconnected']

const stop_reason_labels = ['', 'breakpoint', 'step', 'exception', 'pause', 'entry', 'goto']

const breakpoint_kind_labels = ['', 'source', 'function', 'data', 'instruction', 'exception']

fn state_label(s int) string {
	if s >= 0 && s < dap_state_labels.len {
		return dap_state_labels[s]
	}
	return 'unknown'
}

// ═══════════════════════════════════════════════════════════════════════
// REST API (vweb)
// ═══════════════════════════════════════════════════════════════════════

struct DapApp {
	vweb.Context
}

['/health']
fn (mut app DapApp) health() vweb.Result {
	return app.json({'status': 'ok', 'cartridge': 'dap-mcp', 'version': '0.1.0'})
}

['/types']
fn (mut app DapApp) types() vweb.Result {
	return app.json({
		'states':           dap_state_labels
		'stop_reasons':     stop_reason_labels
		'breakpoint_kinds': breakpoint_kind_labels
	})
}

['/sessions'; post]
fn (mut app DapApp) create_session() vweb.Result {
	slot := C.dap_init()
	if slot < 0 {
		return app.json({'error': 'no slots available'})
	}
	return app.json({'slot': slot, 'state': 'not_started'})
}

['/sessions/:slot/launch'; post]
fn (mut app DapApp) launch(slot string) vweb.Result {
	s := slot.int()
	r := C.dap_launch(s)
	if r < 0 {
		return app.json({'error': 'invalid transition', 'code': r})
	}
	return app.json({'slot': s, 'state': 'launched'})
}

['/sessions/:slot/continue'; post]
fn (mut app DapApp) do_continue(slot string) vweb.Result {
	s := slot.int()
	r := C.dap_continue(s)
	if r < 0 {
		return app.json({'error': 'invalid transition', 'code': r})
	}
	return app.json({'slot': s, 'state': 'running'})
}

['/sessions/:slot/state']
fn (mut app DapApp) get_state(slot string) vweb.Result {
	s := slot.int()
	st := C.dap_state(s)
	return app.json({
		'slot':        s
		'state':       state_label(st)
		'can_inspect': C.dap_can_inspect(s) == 1
	})
}

// ═══════════════════════════════════════════════════════════════════════
// GraphQL Schema
// ═══════════════════════════════════════════════════════════════════════

const graphql_schema = '
type Query {
  health: Health!
  session(slot: Int!): DapSession
  types: TypeInfo!
}

type Mutation {
  createSession: DapSession!
  launch(slot: Int!): DapSession!
  configure(slot: Int!): DapSession!
  continue(slot: Int!): DapSession!
  stopped(slot: Int!, reason: Int!): DapSession!
  terminate(slot: Int!): DapSession!
  disconnect(slot: Int!): DapSession!
  addBreakpoint(slot: Int!, kind: Int!): BreakpointResult!
}

type Health {
  status: String!
  cartridge: String!
  version: String!
}

type DapSession {
  slot: Int!
  state: String!
  canInspect: Boolean!
  canSetBreakpoints: Boolean!
}

type BreakpointResult {
  slot: Int!
  breakpointIndex: Int!
}

type TypeInfo {
  states: [String!]!
  stopReasons: [String!]!
  breakpointKinds: [String!]!
}
'

// ═══════════════════════════════════════════════════════════════════════
// gRPC Proto Definition
// ═══════════════════════════════════════════════════════════════════════

const grpc_proto = '
syntax = "proto3";
package dap_mcp;

service DapService {
  rpc CreateSession(Empty) returns (SessionResponse);
  rpc Launch(SlotRequest) returns (SessionResponse);
  rpc Configure(SlotRequest) returns (SessionResponse);
  rpc Continue(SlotRequest) returns (SessionResponse);
  rpc Stopped(StopRequest) returns (SessionResponse);
  rpc Terminate(SlotRequest) returns (SessionResponse);
  rpc Disconnect(SlotRequest) returns (SessionResponse);
  rpc GetState(SlotRequest) returns (SessionResponse);
  rpc AddBreakpoint(BreakpointRequest) returns (BreakpointResponse);
  rpc Health(Empty) returns (HealthResponse);
}

message Empty {}
message SlotRequest { int32 slot = 1; }
message StopRequest { int32 slot = 1; int32 reason = 2; }
message BreakpointRequest { int32 slot = 1; int32 kind = 2; }
message SessionResponse { int32 slot = 1; string state = 2; bool can_inspect = 3; }
message BreakpointResponse { int32 slot = 1; int32 breakpoint_index = 2; }
message HealthResponse { string status = 1; string cartridge = 2; string version = 3; }
'
