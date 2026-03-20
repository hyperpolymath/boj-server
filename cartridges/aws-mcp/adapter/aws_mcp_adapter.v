// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// aws_mcp_adapter.v — V-lang REST adapter for aws-mcp cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.
// Exposes AWS Signature V4 authentication, multi-service routing
// (S3/Lambda/DynamoDB/SQS/CloudWatch/IAM/STS), rate-limit handling,
// action invocation, and mutability checks.

module aws_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -laws_mcp

fn C.aws_mcp_can_transition(from int, to int) int
fn C.aws_mcp_authenticate(region_ptr &u8, region_len int) int
fn C.aws_mcp_deauthenticate(slot_idx int) int
fn C.aws_mcp_session_state(slot_idx int) int
fn C.aws_mcp_throttle(slot_idx int) int
fn C.aws_mcp_unthrottle(slot_idx int) int
fn C.aws_mcp_signal_error(slot_idx int) int
fn C.aws_mcp_action_service(action int) int
fn C.aws_mcp_action_is_mutating(action int) int
fn C.aws_mcp_record_call(slot_idx int, action int) int
fn C.aws_mcp_call_count(slot_idx int) int
fn C.aws_mcp_service_count() int
fn C.aws_mcp_action_count() int
fn C.aws_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {
	unauthenticated = 0
	authenticated   = 1
	rate_limited    = 2
	err             = 3
}

enum AwsService {
	s3         = 0
	lambda     = 1
	dynamodb   = 2
	sqs        = 3
	cloudwatch = 4
	iam        = 5
	sts        = 6
}

fn state_label(s int) string {
	return match s {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'rate_limited' }
		3 { 'error' }
		else { 'unknown' }
	}
}

fn service_label(s int) string {
	return match s {
		0 { 's3' }
		1 { 'lambda' }
		2 { 'dynamodb' }
		3 { 'sqs' }
		4 { 'cloudwatch' }
		5 { 'iam' }
		6 { 'sts' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct AuthResponse {
	slot   int
	state  string
	region string
}

struct StateResponse {
	slot  int
	state string
}

struct ActionResponse {
	slot     int
	action   int
	service  string
	mutating bool
	calls    int
}

struct TransitionResponse {
	from  int
	to    int
	valid bool
}

struct StatusResponse {
	slot          int
	state         string
	region        string
	service_count int
	action_count  int
	call_count    int
}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn authenticate(region string) !AuthResponse {
	slot := C.aws_mcp_authenticate(region.str, region.len)
	if slot == -1 {
		return error('no session slots available')
	}
	if slot == -2 {
		return error('region string too long')
	}
	return AuthResponse{
		slot: slot
		state: 'authenticated'
		region: region
	}
}

pub fn deauthenticate(slot int) !string {
	result := C.aws_mcp_deauthenticate(slot)
	return match result {
		0 { 'deauthenticated slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('invalid state transition') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn session_state(slot int) StateResponse {
	s := C.aws_mcp_session_state(slot)
	return StateResponse{ slot: slot, state: state_label(s) }
}

pub fn invoke_action(slot int, action int) !ActionResponse {
	result := C.aws_mcp_record_call(slot, action)
	if result == -1 {
		return error('slot not active')
	}
	if result == -2 {
		return error('not authenticated')
	}
	if result == -3 {
		return error('invalid action')
	}
	svc := C.aws_mcp_action_service(action)
	mutating := C.aws_mcp_action_is_mutating(action) == 1
	calls := C.aws_mcp_call_count(slot)
	return ActionResponse{
		slot: slot
		action: action
		service: service_label(svc)
		mutating: mutating
		calls: calls
	}
}

pub fn status(slot int) StatusResponse {
	s := C.aws_mcp_session_state(slot)
	calls := C.aws_mcp_call_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(s)
		region: ''
		service_count: C.aws_mcp_service_count()
		action_count: C.aws_mcp_action_count()
		call_count: calls
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.aws_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

pub fn reset() {
	C.aws_mcp_reset()
}
