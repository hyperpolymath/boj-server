// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Comms-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (comms_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides provider session lifecycle management, operation execution,
// and state machine inspection via the BoJ triple adapter.

module comms_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against comms_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.comms_authenticate(provider int) int
fn C.comms_logout(slot_idx int) int
fn C.comms_begin_operation(slot_idx int) int
fn C.comms_end_operation(slot_idx int) int
fn C.comms_state(slot_idx int) int
fn C.comms_can_transition(from int, to int) int
fn C.comms_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum SessionState {
	unauthenticated = 0
	authenticated = 1
	operating = 2
	auth_error = 3
}

enum CommsProvider {
	gmail = 1
	google_calendar = 2
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

fn provider_label(p CommsProvider) string {
	return match p {
		.gmail { 'Gmail' }
		.google_calendar { 'Google Calendar' }
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
		'gmail' { int(CommsProvider.gmail) }
		'google_calendar' { int(CommsProvider.google_calendar) }
		else { return error('unknown provider: ${provider_name}') }
	}
	slot := C.comms_authenticate(p)
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
	result := C.comms_logout(slot)
	return match result {
		0 { 'logged out slot ${slot}' }
		-1 { return error('slot ${slot} not active or already unauthenticated') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.comms_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn begin_operation(slot int) !string {
	result := C.comms_begin_operation(slot)
	return match result {
		0 { 'operation started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot begin operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_operation(slot int) !string {
	result := C.comms_end_operation(slot)
	return match result {
		0 { 'operation completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.comms_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.comms_reset()
}

// ═══════════════════════════════════════════════════════════════════════
// Gmail Provider — C FFI declarations
// ═══════════════════════════════════════════════════════════════════════

fn C.comms_gmail_set_credentials(slot_idx int, token_ptr &u8, token_len usize) int
fn C.comms_gmail_send(slot_idx int, json_ptr &u8, json_len usize) int
fn C.comms_gmail_read(slot_idx int, msg_id_ptr &u8, msg_id_len usize) int
fn C.comms_gmail_search(slot_idx int, query_ptr &u8, query_len usize) int
fn C.comms_gmail_labels(slot_idx int) int
fn C.comms_gmail_read_result(slot_idx int, out_ptr &u8, out_cap usize) int

// ═══════════════════════════════════════════════════════════════════════
// Gmail Provider — Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

struct GmailResponse {
	slot     int
	provider string
	result   string
}

/// Read the JSON result buffer from a Gmail operation.
fn read_gmail_result(slot int) string {
	mut buf := []u8{len: 4096}
	rc := C.comms_gmail_read_result(slot, buf.data, usize(buf.len))
	if rc <= 0 {
		return '{}'
	}
	return buf[..rc].bytestr()
}

/// Authenticate with Gmail and store an OAuth token.
pub fn gmail_authenticate(token string) !GmailResponse {
	slot := C.comms_authenticate(int(CommsProvider.gmail))
	if slot < 0 {
		return error('no session slots available for Gmail')
	}
	rc := C.comms_gmail_set_credentials(slot, token.str, usize(token.len))
	if rc < 0 {
		_ = C.comms_logout(slot)
		return error('failed to set Gmail credentials on slot ${slot}')
	}
	return GmailResponse{
		slot: slot
		provider: 'gmail'
		result: 'authenticated'
	}
}

/// Send an email via Gmail.
pub fn gmail_send(slot int, message_json string) !GmailResponse {
	rc := C.comms_gmail_send(slot, message_json.str, usize(message_json.len))
	if rc < 0 {
		return error('gmail_send failed on slot ${slot}')
	}
	return GmailResponse{
		slot: slot
		provider: 'gmail'
		result: read_gmail_result(slot)
	}
}

/// Read an email by message ID via Gmail.
pub fn gmail_read(slot int, msg_id string) !GmailResponse {
	rc := C.comms_gmail_read(slot, msg_id.str, usize(msg_id.len))
	if rc < 0 {
		return error('gmail_read failed on slot ${slot}')
	}
	return GmailResponse{
		slot: slot
		provider: 'gmail'
		result: read_gmail_result(slot)
	}
}

/// Search emails via Gmail.
pub fn gmail_search(slot int, query string) !GmailResponse {
	rc := C.comms_gmail_search(slot, query.str, usize(query.len))
	if rc < 0 {
		return error('gmail_search failed on slot ${slot}')
	}
	return GmailResponse{
		slot: slot
		provider: 'gmail'
		result: read_gmail_result(slot)
	}
}

/// List Gmail labels.
pub fn gmail_labels(slot int) !GmailResponse {
	rc := C.comms_gmail_labels(slot)
	if rc < 0 {
		return error('gmail_labels failed on slot ${slot}')
	}
	return GmailResponse{
		slot: slot
		provider: 'gmail'
		result: read_gmail_result(slot)
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Google Calendar Provider — C FFI declarations
// ═══════════════════════════════════════════════════════════════════════

fn C.comms_calendar_set_credentials(slot_idx int, token_ptr &u8, token_len usize) int
fn C.comms_calendar_events(slot_idx int, json_ptr &u8, json_len usize) int
fn C.comms_calendar_create_event(slot_idx int, json_ptr &u8, json_len usize) int
fn C.comms_calendar_free_busy(slot_idx int, json_ptr &u8, json_len usize) int
fn C.comms_calendar_read_result(slot_idx int, out_ptr &u8, out_cap usize) int

// ═══════════════════════════════════════════════════════════════════════
// Google Calendar Provider — Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

struct CalendarResponse {
	slot     int
	provider string
	result   string
}

/// Read the JSON result buffer from a Calendar operation.
fn read_calendar_result(slot int) string {
	mut buf := []u8{len: 4096}
	rc := C.comms_calendar_read_result(slot, buf.data, usize(buf.len))
	if rc <= 0 {
		return '{}'
	}
	return buf[..rc].bytestr()
}

/// Authenticate with Google Calendar and store an OAuth token.
pub fn calendar_authenticate(token string) !CalendarResponse {
	slot := C.comms_authenticate(int(CommsProvider.google_calendar))
	if slot < 0 {
		return error('no session slots available for Google Calendar')
	}
	rc := C.comms_calendar_set_credentials(slot, token.str, usize(token.len))
	if rc < 0 {
		_ = C.comms_logout(slot)
		return error('failed to set Calendar credentials on slot ${slot}')
	}
	return CalendarResponse{
		slot: slot
		provider: 'google_calendar'
		result: 'authenticated'
	}
}

/// List calendar events.
pub fn calendar_events(slot int, filter_json string) !CalendarResponse {
	rc := C.comms_calendar_events(slot, filter_json.str, usize(filter_json.len))
	if rc < 0 {
		return error('calendar_events failed on slot ${slot}')
	}
	return CalendarResponse{
		slot: slot
		provider: 'google_calendar'
		result: read_calendar_result(slot)
	}
}

/// Create a calendar event.
pub fn calendar_create_event(slot int, event_json string) !CalendarResponse {
	rc := C.comms_calendar_create_event(slot, event_json.str, usize(event_json.len))
	if rc < 0 {
		return error('calendar_create_event failed on slot ${slot}')
	}
	return CalendarResponse{
		slot: slot
		provider: 'google_calendar'
		result: read_calendar_result(slot)
	}
}

/// Query free/busy information.
pub fn calendar_free_busy(slot int, range_json string) !CalendarResponse {
	rc := C.comms_calendar_free_busy(slot, range_json.str, usize(range_json.len))
	if rc < 0 {
		return error('calendar_free_busy failed on slot ${slot}')
	}
	return CalendarResponse{
		slot: slot
		provider: 'google_calendar'
		result: read_calendar_result(slot)
	}
}
