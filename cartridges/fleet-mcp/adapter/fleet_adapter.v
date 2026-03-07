// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Fleet-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (fleet_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides the 6-bot gate policy interface for gitbot-fleet orchestration.

module fleet_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against fleet_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.fleet_reset()
fn C.fleet_record_gate(gate int, passed int, score int) int
fn C.fleet_has_mandatory() int
fn C.fleet_has_all() int
fn C.fleet_status() int
fn C.fleet_gate_score(gate int) int

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

const bot_names = ['rhodibot', 'echidnabot', 'sustainabot', 'panicbot', 'glambot', 'seambot']

fn status_label(s int) string {
	return match s {
		0 { 'unscanned' }
		1 { 'scanning' }
		2 { 'healthy' }
		3 { 'degraded' }
		4 { 'blocked' }
		else { 'unknown' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct GateResult {
	bot    string
	passed bool
	score  int
}

struct FleetStatusResponse {
	status         string
	mandatory_met  bool
	all_passed     bool
	gates          []GateResult
}

struct RecordGateRequest {
	bot    string
	passed bool
	score  int
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

pub fn get_status() FleetStatusResponse {
	mut gates := []GateResult{}
	for i in 0 .. 6 {
		score := C.fleet_gate_score(i + 1)
		gates << GateResult{
			bot: bot_names[i]
			passed: score > 0
			score: score
		}
	}
	return FleetStatusResponse{
		status: status_label(C.fleet_status())
		mandatory_met: C.fleet_has_mandatory() == 1
		all_passed: C.fleet_has_all() == 1
		gates: gates
	}
}

pub fn record_gate(req RecordGateRequest) !string {
	gate_idx := match req.bot {
		'rhodibot' { 1 }
		'echidnabot' { 2 }
		'sustainabot' { 3 }
		'panicbot' { 4 }
		'glambot' { 5 }
		'seambot' { 6 }
		else { return error('unknown bot: ${req.bot}') }
	}
	passed_int := if req.passed { 1 } else { 0 }
	result := C.fleet_record_gate(gate_idx, passed_int, req.score)
	if result != 0 {
		return error('failed to record gate (code ${result})')
	}
	return 'recorded ${req.bot}: passed=${req.passed}, score=${req.score}'
}

pub fn reset() {
	C.fleet_reset()
}
