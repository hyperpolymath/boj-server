// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// ML-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (ml_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides provider session lifecycle management, operation execution,
// and state machine inspection via the BoJ triple adapter.

module ml_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against ml_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.ml_authenticate(provider int) int
fn C.ml_logout(slot_idx int) int
fn C.ml_begin_operation(slot_idx int) int
fn C.ml_end_operation(slot_idx int) int
fn C.ml_state(slot_idx int) int
fn C.ml_can_transition(from int, to int) int
fn C.ml_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum SessionState {
	unauthenticated = 0
	authenticated = 1
	operating = 2
	auth_error = 3
}

enum MlProvider {
	hugging_face = 1
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'auth_error' }
		else { 'unknown' }
	}
}

fn provider_label(p MlProvider) string {
	return match p {
		.hugging_face { 'Hugging Face' }
		.custom { 'Custom' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct AuthResponse {
	slot     int
	provider string
	state    string
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

pub fn authenticate(provider_name string) !AuthResponse {
	p := match provider_name {
		'huggingface' { int(MlProvider.hugging_face) }
		else { return error('unknown provider: ${provider_name}') }
	}
	slot := C.ml_authenticate(p)
	if slot < 0 {
		return error('no session slots available')
	}
	return AuthResponse{
		slot: slot
		provider: provider_name
		state: 'authenticated'
	}
}

pub fn logout(slot int) !string {
	result := C.ml_logout(slot)
	return match result {
		0 { 'logged out slot ${slot}' }
		-1 { return error('slot ${slot} not active or already unauthenticated') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.ml_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn begin_operation(slot int) !string {
	result := C.ml_begin_operation(slot)
	return match result {
		0 { 'operation started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot begin operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_operation(slot int) !string {
	result := C.ml_end_operation(slot)
	return match result {
		0 { 'operation completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.ml_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.ml_reset()
}

// ═══════════════════════════════════════════════════════════════════════
// Hugging Face Provider — C FFI declarations
// ═══════════════════════════════════════════════════════════════════════

fn C.ml_hf_set_credentials(slot_idx int, token_ptr &u8, token_len usize) int
fn C.ml_hf_search_models(slot_idx int, query_ptr &u8, query_len usize) int
fn C.ml_hf_model_info(slot_idx int, model_id_ptr &u8, model_id_len usize) int
fn C.ml_hf_inference(slot_idx int, json_ptr &u8, json_len usize) int
fn C.ml_hf_list_spaces(slot_idx int) int
fn C.ml_hf_space_info(slot_idx int, space_id_ptr &u8, space_id_len usize) int
fn C.ml_hf_list_datasets(slot_idx int) int
fn C.ml_hf_dataset_info(slot_idx int, dataset_id_ptr &u8, dataset_id_len usize) int
fn C.ml_hf_read_result(slot_idx int, out_ptr &u8, out_cap usize) int

// ═══════════════════════════════════════════════════════════════════════
// Hugging Face Provider — Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

struct HfResponse {
	slot     int
	provider string
	result   string
}

/// Read the JSON result buffer from a Hugging Face operation.
fn read_hf_result(slot int) string {
	mut buf := []u8{len: 4096}
	rc := C.ml_hf_read_result(slot, buf.data, usize(buf.len))
	if rc <= 0 {
		return '{}'
	}
	return buf[..rc].bytestr()
}

/// Authenticate with Hugging Face and store an API token.
pub fn hf_authenticate(token string) !HfResponse {
	slot := C.ml_authenticate(int(MlProvider.hugging_face))
	if slot < 0 {
		return error('no session slots available for Hugging Face')
	}
	rc := C.ml_hf_set_credentials(slot, token.str, usize(token.len))
	if rc < 0 {
		_ = C.ml_logout(slot)
		return error('failed to set Hugging Face credentials on slot ${slot}')
	}
	return HfResponse{
		slot: slot
		provider: 'huggingface'
		result: 'authenticated'
	}
}

/// Search for models on Hugging Face.
pub fn hf_search_models(slot int, query string) !HfResponse {
	rc := C.ml_hf_search_models(slot, query.str, usize(query.len))
	if rc < 0 {
		return error('hf_search_models failed on slot ${slot}')
	}
	return HfResponse{
		slot: slot
		provider: 'huggingface'
		result: read_hf_result(slot)
	}
}

/// Get model info from Hugging Face.
pub fn hf_model_info(slot int, model_id string) !HfResponse {
	rc := C.ml_hf_model_info(slot, model_id.str, usize(model_id.len))
	if rc < 0 {
		return error('hf_model_info failed on slot ${slot}')
	}
	return HfResponse{
		slot: slot
		provider: 'huggingface'
		result: read_hf_result(slot)
	}
}

/// Run inference on a Hugging Face model.
pub fn hf_inference(slot int, payload_json string) !HfResponse {
	rc := C.ml_hf_inference(slot, payload_json.str, usize(payload_json.len))
	if rc < 0 {
		return error('hf_inference failed on slot ${slot}')
	}
	return HfResponse{
		slot: slot
		provider: 'huggingface'
		result: read_hf_result(slot)
	}
}

/// List Spaces on Hugging Face.
pub fn hf_list_spaces(slot int) !HfResponse {
	rc := C.ml_hf_list_spaces(slot)
	if rc < 0 {
		return error('hf_list_spaces failed on slot ${slot}')
	}
	return HfResponse{
		slot: slot
		provider: 'huggingface'
		result: read_hf_result(slot)
	}
}

/// Get Space info from Hugging Face.
pub fn hf_space_info(slot int, space_id string) !HfResponse {
	rc := C.ml_hf_space_info(slot, space_id.str, usize(space_id.len))
	if rc < 0 {
		return error('hf_space_info failed on slot ${slot}')
	}
	return HfResponse{
		slot: slot
		provider: 'huggingface'
		result: read_hf_result(slot)
	}
}

/// List datasets on Hugging Face.
pub fn hf_list_datasets(slot int) !HfResponse {
	rc := C.ml_hf_list_datasets(slot)
	if rc < 0 {
		return error('hf_list_datasets failed on slot ${slot}')
	}
	return HfResponse{
		slot: slot
		provider: 'huggingface'
		result: read_hf_result(slot)
	}
}

/// Get dataset info from Hugging Face.
pub fn hf_dataset_info(slot int, dataset_id string) !HfResponse {
	rc := C.ml_hf_dataset_info(slot, dataset_id.str, usize(dataset_id.len))
	if rc < 0 {
		return error('hf_dataset_info failed on slot ${slot}')
	}
	return HfResponse{
		slot: slot
		provider: 'huggingface'
		result: read_hf_result(slot)
	}
}
