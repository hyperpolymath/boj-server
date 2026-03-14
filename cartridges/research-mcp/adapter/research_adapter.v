// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Research-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (research_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides provider session lifecycle management, operation execution,
// and state machine inspection via the BoJ triple adapter.

module research_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against research_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.research_authenticate(provider int) int
fn C.research_logout(slot_idx int) int
fn C.research_begin_operation(slot_idx int) int
fn C.research_end_operation(slot_idx int) int
fn C.research_state(slot_idx int) int
fn C.research_can_transition(from int, to int) int
fn C.research_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum SessionState {
	unauthenticated = 0
	authenticated = 1
	operating = 2
	auth_error = 3
}

enum ResearchProvider {
	scholar_gateway = 1
	semantic_scholar = 2
	open_alex = 3
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

fn provider_label(p ResearchProvider) string {
	return match p {
		.scholar_gateway { 'Scholar Gateway' }
		.semantic_scholar { 'Semantic Scholar' }
		.open_alex { 'OpenAlex' }
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
		'scholar_gateway' { int(ResearchProvider.scholar_gateway) }
		'semantic_scholar' { int(ResearchProvider.semantic_scholar) }
		'open_alex' { int(ResearchProvider.open_alex) }
		else { return error('unknown provider: ${provider_name}') }
	}
	slot := C.research_authenticate(p)
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
	result := C.research_logout(slot)
	return match result {
		0 { 'logged out slot ${slot}' }
		-1 { return error('slot ${slot} not active or already unauthenticated') }
		-2 { return error('invalid state transition for slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(slot int) StateResponse {
	s := C.research_state(slot)
	return StateResponse{
		slot: slot
		state: state_label(s)
	}
}

pub fn begin_operation(slot int) !string {
	result := C.research_begin_operation(slot)
	return match result {
		0 { 'operation started on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot begin operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_operation(slot int) !string {
	result := C.research_end_operation(slot)
	return match result {
		0 { 'operation completed on slot ${slot}' }
		-1 { return error('slot ${slot} not active') }
		-2 { return error('cannot end operation from current state') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn can_transition(from int, to int) TransitionResponse {
	allowed := C.research_can_transition(from, to) == 1
	return TransitionResponse{
		from: state_label(from)
		to: state_label(to)
		allowed: allowed
	}
}

pub fn reset() {
	C.research_reset()
}

// ═══════════════════════════════════════════════════════════════════════
// Research Provider — C FFI declarations
// ═══════════════════════════════════════════════════════════════════════

fn C.research_set_credentials(slot_idx int, key_ptr &u8, key_len usize) int
fn C.research_search_papers(slot_idx int, query_ptr &u8, query_len usize) int
fn C.research_paper_details(slot_idx int, id_ptr &u8, id_len usize) int
fn C.research_paper_citations(slot_idx int, id_ptr &u8, id_len usize) int
fn C.research_paper_references(slot_idx int, id_ptr &u8, id_len usize) int
fn C.research_author_search(slot_idx int, name_ptr &u8, name_len usize) int
fn C.research_author_papers(slot_idx int, id_ptr &u8, id_len usize) int
fn C.research_read_result(slot_idx int, out_ptr &u8, out_cap usize) int

// ═══════════════════════════════════════════════════════════════════════
// Research Provider — Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

struct ResearchResponse {
	slot     int
	provider string
	result   string
}

/// Read the JSON result buffer from a research operation.
fn read_research_result(slot int) string {
	mut buf := []u8{len: 4096}
	rc := C.research_read_result(slot, buf.data, usize(buf.len))
	if rc <= 0 {
		return '{}'
	}
	return buf[..rc].bytestr()
}

/// Authenticate with a research provider and store an API key.
pub fn provider_authenticate(provider_name string, api_key string) !ResearchResponse {
	auth := authenticate(provider_name) or { return error(err.str()) }
	rc := C.research_set_credentials(auth.slot, api_key.str, usize(api_key.len))
	if rc < 0 {
		_ = C.research_logout(auth.slot)
		return error('failed to set credentials on slot ${auth.slot}')
	}
	return ResearchResponse{
		slot: auth.slot
		provider: provider_name
		result: 'authenticated'
	}
}

/// Search for papers.
pub fn search_papers(slot int, query string) !ResearchResponse {
	rc := C.research_search_papers(slot, query.str, usize(query.len))
	if rc < 0 {
		return error('search_papers failed on slot ${slot}')
	}
	return ResearchResponse{
		slot: slot
		provider: 'research'
		result: read_research_result(slot)
	}
}

/// Get paper details by ID.
pub fn paper_details(slot int, paper_id string) !ResearchResponse {
	rc := C.research_paper_details(slot, paper_id.str, usize(paper_id.len))
	if rc < 0 {
		return error('paper_details failed on slot ${slot}')
	}
	return ResearchResponse{
		slot: slot
		provider: 'research'
		result: read_research_result(slot)
	}
}

/// Get citations for a paper.
pub fn paper_citations(slot int, paper_id string) !ResearchResponse {
	rc := C.research_paper_citations(slot, paper_id.str, usize(paper_id.len))
	if rc < 0 {
		return error('paper_citations failed on slot ${slot}')
	}
	return ResearchResponse{
		slot: slot
		provider: 'research'
		result: read_research_result(slot)
	}
}

/// Get references from a paper.
pub fn paper_references(slot int, paper_id string) !ResearchResponse {
	rc := C.research_paper_references(slot, paper_id.str, usize(paper_id.len))
	if rc < 0 {
		return error('paper_references failed on slot ${slot}')
	}
	return ResearchResponse{
		slot: slot
		provider: 'research'
		result: read_research_result(slot)
	}
}

/// Search for authors by name.
pub fn author_search(slot int, name string) !ResearchResponse {
	rc := C.research_author_search(slot, name.str, usize(name.len))
	if rc < 0 {
		return error('author_search failed on slot ${slot}')
	}
	return ResearchResponse{
		slot: slot
		provider: 'research'
		result: read_research_result(slot)
	}
}

/// Get papers by an author.
pub fn author_papers(slot int, author_id string) !ResearchResponse {
	rc := C.research_author_papers(slot, author_id.str, usize(author_id.len))
	if rc < 0 {
		return error('author_papers failed on slot ${slot}')
	}
	return ResearchResponse{
		slot: slot
		provider: 'research'
		result: read_research_result(slot)
	}
}
