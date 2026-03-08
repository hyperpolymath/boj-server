// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Agent-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (agent_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides OODA loop enforcement for AI agent sessions.
// Agents must follow Observe -> Orient -> Decide -> Act.

module agent_adapter

import json

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
// Types
// ═══════════════════════════════════════════════════════════════════════

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

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct SessionResponse {
	session_id int
	state      string
	loop_count int
}

struct TransitionResponse {
	session_id int
	from       string
	to         string
	success    bool
	next_state string
}

struct ValidationResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

pub fn new_session() !SessionResponse {
	idx := C.agent_new_session()
	if idx < 0 {
		return error('no session slots available')
	}
	return SessionResponse{
		session_id: idx
		state: 'observe'
		loop_count: 0
	}
}

pub fn end_session(idx int) !string {
	result := C.agent_end_session(idx)
	if result != 0 {
		return error('failed to end session ${idx}')
	}
	return 'session ${idx} ended'
}

pub fn get_session(idx int) !SessionResponse {
	s := C.agent_state(idx)
	if s < 0 {
		return error('session ${idx} not found')
	}
	return SessionResponse{
		session_id: idx
		state: state_label(s)
		loop_count: C.agent_loop_count(idx)
	}
}

pub fn transition(idx int, target_name string) !TransitionResponse {
	target := state_from_name(target_name)!
	current := C.agent_state(idx)
	if current < 0 {
		return error('session ${idx} not found')
	}
	result := C.agent_transition(idx, target)
	if result == -1 {
		return error('invalid transition from ${state_label(current)} to ${target_name}')
	}
	if result == -2 {
		return error('session ${idx} not found')
	}
	next := C.agent_next_state(target)
	return TransitionResponse{
		session_id: idx
		from: state_label(current)
		to: target_name
		success: true
		next_state: state_label(next)
	}
}

pub fn advance(idx int) !TransitionResponse {
	current := C.agent_state(idx)
	if current < 0 {
		return error('session ${idx} not found')
	}
	next := C.agent_next_state(current)
	return transition(idx, state_label(next))
}

pub fn halt(idx int) !TransitionResponse {
	return transition(idx, 'halted')
}

pub fn validate(from_name string, to_name string) !ValidationResponse {
	from := state_from_name(from_name)!
	to := state_from_name(to_name)!
	allowed := C.agent_validate_ooda(from, to) == 1
	return ValidationResponse{
		from: from_name
		to: to_name
		allowed: allowed
	}
}

pub fn reset() {
	C.agent_reset()
}

// ═══════════════════════════════════════════════════════════════════════
// Protocol Functions (v0.2.0 — from proven-agentic)
// ═══════════════════════════════════════════════════════════════════════

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

fn coordination_label(c int) string {
	return match c {
		0 { 'Solo' }
		1 { 'Collaborative' }
		2 { 'Competitive' }
		3 { 'Hierarchical' }
		4 { 'Swarm' }
		5 { 'Consensus' }
		else { 'Unknown' }
	}
}

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

fn memory_type_label(m int) string {
	return match m {
		0 { 'Working' }
		1 { 'Episodic' }
		2 { 'Semantic' }
		3 { 'Procedural' }
		4 { 'Shared' }
		else { 'Unknown' }
	}
}

struct ToolCallInfo {
	kind                  string
	has_side_effects      bool
	requires_safety_check bool
}

struct SafetyCheckInfo {
	outcome          string
	allows_execution bool
	needs_human      bool
}

struct CoordinationInfo {
	strategy       string
	is_multi_agent bool
}

pub fn tool_call_info(kind string) !ToolCallInfo {
	tc := match kind.to_lower() {
		'execute' { 0 }
		'query' { 1 }
		'transform' { 2 }
		'communicate' { 3 }
		'delegate' { 4 }
		'escalate' { 5 }
		else { return error('unknown tool call: ${kind}') }
	}
	return ToolCallInfo{
		kind: tool_call_label(tc)
		has_side_effects: C.agent_tool_has_side_effects(tc) == 1
		requires_safety_check: C.agent_tool_requires_safety(tc) == 1
	}
}

pub fn safety_check_info(outcome string) !SafetyCheckInfo {
	sc := match outcome.to_lower() {
		'approved' { 0 }
		'denied' { 1 }
		'escalated' { 2 }
		'timeout' { 3 }
		'sandboxed' { 4 }
		'humanrequired', 'human_required' { 5 }
		else { return error('unknown safety check: ${outcome}') }
	}
	return SafetyCheckInfo{
		outcome: safety_check_label(sc)
		allows_execution: C.agent_safety_allows_exec(sc) == 1
		needs_human: C.agent_safety_needs_human(sc) == 1
	}
}

pub fn coordination_info(strategy string) !CoordinationInfo {
	c := match strategy.to_lower() {
		'solo' { 0 }
		'collaborative' { 1 }
		'competitive' { 2 }
		'hierarchical' { 3 }
		'swarm' { 4 }
		'consensus' { 5 }
		else { return error('unknown coordination: ${strategy}') }
	}
	return CoordinationInfo{
		strategy: coordination_label(c)
		is_multi_agent: C.agent_coordination_is_multi(c) == 1
	}
}
