// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// IaC-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (iac_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides plan-before-apply enforcement, workspace lifecycle management,
// and state machine inspection via the BoJ triple adapter.

module iac_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against iac_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.iac_init(tool int) int
fn C.iac_plan(slot_idx int, plan_hash u32) int
fn C.iac_apply(slot_idx int) int
fn C.iac_destroy(slot_idx int) int
fn C.iac_state(slot_idx int) int
fn C.iac_has_plan(slot_idx int) int
fn C.iac_can_transition(from int, to int) int
fn C.iac_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum IacState {
	uninitialized = 0
	initialized = 1
	planned = 2
	applying = 3
	applied = 4
	iac_error = 5
}

enum IacTool {
	terraform = 1
	pulumi = 2
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'uninitialized' }
		1 { 'initialized' }
		2 { 'planned' }
		3 { 'applying' }
		4 { 'applied' }
		5 { 'error' }
		else { 'unknown' }
	}
}

fn tool_label(t IacTool) string {
	return match t {
		.terraform { 'Terraform' }
		.pulumi { 'Pulumi' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct InitResponse {
	slot  int
	tool  string
	state string
}

struct PlanResponse {
	slot      int
	state     string
	has_plan  bool
}

struct StateResponse {
	slot  int
	state string
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

pub fn init_workspace(tool_name string) !InitResponse {
	t := match tool_name {
		'terraform' { int(IacTool.terraform) }
		'pulumi' { int(IacTool.pulumi) }
		else { return error('unknown IaC tool: ${tool_name}') }
	}
	slot := C.iac_init(t)
	if slot < 0 {
		return error('no workspace slots available')
	}
	return InitResponse{
		slot: slot
		tool: tool_name
		state: 'initialized'
	}
}

pub fn plan(slot int, plan_hash u32) !PlanResponse {
	result := C.iac_plan(slot, plan_hash)
	return match result {
		0 {
			PlanResponse{
				slot: slot
				state: 'planned'
				has_plan: true
			}
		}
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot plan from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn apply(slot int) !string {
	result := C.iac_apply(slot)
	return match result {
		0 { 'applied infrastructure on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot apply: no plan generated (plan required before apply)') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn destroy(slot int) !string {
	result := C.iac_destroy(slot)
	return match result {
		0 { 'destroyed resources on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition for destroy') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.iac_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn has_plan(slot int) bool {
	return C.iac_has_plan(slot) == 1
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.iac_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.iac_reset()
}
