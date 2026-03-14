// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// UMS-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (ums_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides level lifecycle management, ABI validation, project CRUD,
// and template operations via the BoJ triple adapter.
//
// State machine:
//   Idle -> ProjectOpen -> LevelLoaded -> Validating -> Valid/Invalid -> Saved
//   Any -> Idle (close project)

module ums_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against ums_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.ums_create_project(name_ptr &u8, name_len usize) int
fn C.ums_open_project(name_ptr &u8, name_len usize) int
fn C.ums_delete_project(slot_idx int) int
fn C.ums_load_level(slot_idx int, name_ptr &u8, name_len usize) int
fn C.ums_save_level(slot_idx int) int
fn C.ums_validate_level_abi(slot_idx int) int
fn C.ums_list_levels(slot_idx int) int
fn C.ums_export_level_config(slot_idx int) int
fn C.ums_load_templates(slot_idx int) int
fn C.ums_instantiate_template(slot_idx int, tmpl_ptr &u8, tmpl_len usize, name_ptr &u8, name_len usize) int
fn C.ums_state(slot_idx int) int
fn C.ums_read_result(slot_idx int, out_ptr &u8, out_cap usize) int
fn C.ums_close(slot_idx int) int
fn C.ums_reset()
fn C.ums_can_transition(from int, to int) int

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum UmsState {
	idle = 0
	project_open = 1
	level_loaded = 2
	validating = 3
	valid = 4
	invalid = 5
	saved = 6
}

fn state_label(s int) string {
	return match s {
		0 { 'idle' }
		1 { 'project_open' }
		2 { 'level_loaded' }
		3 { 'validating' }
		4 { 'valid' }
		5 { 'invalid' }
		6 { 'saved' }
		else { 'unknown' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct UmsResponse {
	slot    int
	state   string
	result  string
}

struct TransitionResponse {
	from    string
	to      string
	allowed bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

/// Read the JSON result buffer from a UMS operation.
fn read_ums_result(slot int) string {
	mut buf := []u8{len: 8192}
	rc := C.ums_read_result(slot, buf.data, usize(buf.len))
	if rc <= 0 {
		return '{}'
	}
	return buf[..rc].bytestr()
}

/// Create a new project.
pub fn create_project(name string) !UmsResponse {
	slot := C.ums_create_project(name.str, usize(name.len))
	if slot < 0 {
		return error('no session slots available for UMS project')
	}
	return UmsResponse{
		slot: slot
		state: 'project_open'
		result: read_ums_result(slot)
	}
}

/// Open an existing project.
pub fn open_project(name string) !UmsResponse {
	slot := C.ums_open_project(name.str, usize(name.len))
	if slot < 0 {
		return error('no session slots available to open UMS project')
	}
	return UmsResponse{
		slot: slot
		state: 'project_open'
		result: read_ums_result(slot)
	}
}

/// Delete a project (requires idle or project_open state).
pub fn delete_project(slot int) !string {
	result := C.ums_delete_project(slot)
	return match result {
		0 { 'project deleted on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot delete: level is loaded (close level first)') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Load a level in the current project.
pub fn load_level(slot int, name string) !UmsResponse {
	result := C.ums_load_level(slot, name.str, usize(name.len))
	if result < 0 {
		return error('load_level failed on slot ${slot} (code ${result})')
	}
	return UmsResponse{
		slot: slot
		state: state_label(C.ums_state(slot))
		result: read_ums_result(slot)
	}
}

/// Save the current level (requires Valid state).
pub fn save_level(slot int) !UmsResponse {
	result := C.ums_save_level(slot)
	if result < 0 {
		return error('save_level failed on slot ${slot} (code ${result}) — must validate first')
	}
	return UmsResponse{
		slot: slot
		state: state_label(C.ums_state(slot))
		result: read_ums_result(slot)
	}
}

/// Run ABI validation on the loaded level.
pub fn validate_level_abi(slot int) !UmsResponse {
	result := C.ums_validate_level_abi(slot)
	if result < 0 {
		return error('validate_level_abi failed on slot ${slot} (code ${result})')
	}
	return UmsResponse{
		slot: slot
		state: state_label(C.ums_state(slot))
		result: read_ums_result(slot)
	}
}

/// List levels in the current project.
pub fn list_levels(slot int) !UmsResponse {
	result := C.ums_list_levels(slot)
	if result < 0 {
		return error('list_levels failed on slot ${slot} (code ${result})')
	}
	return UmsResponse{
		slot: slot
		state: state_label(C.ums_state(slot))
		result: read_ums_result(slot)
	}
}

/// Export the level configuration.
pub fn export_level_config(slot int) !UmsResponse {
	result := C.ums_export_level_config(slot)
	if result < 0 {
		return error('export_level_config failed on slot ${slot} (code ${result})')
	}
	return UmsResponse{
		slot: slot
		state: state_label(C.ums_state(slot))
		result: read_ums_result(slot)
	}
}

/// Load available templates.
pub fn load_templates() !string {
	rc := C.ums_load_templates(0)
	if rc < 0 {
		return error('load_templates failed')
	}
	return '{"templates":[],"count":0}'
}

/// Instantiate a level from a template.
pub fn instantiate_template(slot int, template_name string, level_name string) !UmsResponse {
	result := C.ums_instantiate_template(
		slot,
		template_name.str,
		usize(template_name.len),
		level_name.str,
		usize(level_name.len),
	)
	if result < 0 {
		return error('instantiate_template failed on slot ${slot} (code ${result})')
	}
	return UmsResponse{
		slot: slot
		state: state_label(C.ums_state(slot))
		result: read_ums_result(slot)
	}
}

/// Get the current session state.
pub fn get_state(slot int) UmsResponse {
	s := C.ums_state(slot)
	return UmsResponse{
		slot: slot
		state: state_label(s)
		result: '{}'
	}
}

/// Check if a state transition is valid.
pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.ums_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

/// Close a session.
pub fn close(slot int) !string {
	result := C.ums_close(slot)
	return match result {
		0 { 'session closed on slot ${slot}' }
		-1 { return error('invalid slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Reset all sessions.
pub fn reset() {
	C.ums_reset()
}
