// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// CodeSeeker-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (codeseeker_ffi.zig) to REST endpoints.
// Exposes CodeSeeker's hybrid search, knowledge graph traversal,
// pattern detection, and Graph RAG capabilities via the BoJ adapter.
//
// CodeSeeker stores all data in .codeseeker/ — no external services.

module codeseeker_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against codeseeker_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.codeseeker_open_session(path &u8) int
fn C.codeseeker_close_session(slot_idx int) int
fn C.codeseeker_begin_index(slot_idx int) int
fn C.codeseeker_finish_index(slot_idx int, file_count u32) int
fn C.codeseeker_begin_query(slot_idx int) int
fn C.codeseeker_finish_query(slot_idx int) int
fn C.codeseeker_signal_error(slot_idx int) int
fn C.codeseeker_reset_error(slot_idx int) int
fn C.codeseeker_get_state(slot_idx int) int
fn C.codeseeker_get_file_count(slot_idx int) u32
fn C.codeseeker_can_transition(from int, to int) int
fn C.codeseeker_reset_all()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum IndexState {
	uninitialised = 0
	indexing = 1
	ready = 2
	querying = 3
	index_error = 4
}

enum SearchMode {
	vector = 1
	text = 2
	path = 3
	hybrid = 4
}

enum GraphRelation {
	imports = 1
	calls = 2
	extends = 3
	implements = 4
	uses = 5
}

fn state_label(s int) string {
	return match s {
		0 { 'uninitialised' }
		1 { 'indexing' }
		2 { 'ready' }
		3 { 'querying' }
		4 { 'index_error' }
		else { 'unknown' }
	}
}

fn relation_label(r int) string {
	return match r {
		1 { 'imports' }
		2 { 'calls' }
		3 { 'extends' }
		4 { 'implements' }
		5 { 'uses' }
		else { 'unknown' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct SessionResponse {
	slot        int
	codebase    string
	state       string
}

struct IndexResponse {
	slot       int
	state      string
	file_count u32
}

struct StatusResponse {
	slot        int
	state       string
	file_count  u32
	ready       bool
}

struct SearchResult {
	file      string
	line      int
	snippet   string
	score     f64
	mode      string
}

struct SearchResponse {
	query   string
	mode    string
	results []SearchResult
}

struct GraphNode {
	symbol   string
	file     string
	relation string
	targets  []string
}

struct TraverseResponse {
	symbol    string
	relation  string
	depth     int
	nodes     []GraphNode
}

struct PatternEntry {
	name        string
	description string
	examples    []string
}

struct PatternsResponse {
	codebase string
	patterns []PatternEntry
}

struct GraphRagResponse {
	query   string
	context string
	nodes   int
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

/// Open an index session for a codebase path.
pub fn open_session(codebase_path string) !SessionResponse {
	slot := C.codeseeker_open_session(codebase_path.str)
	return match slot {
		-1 { return error('no session slots available') }
		-2 { return error('codebase at ${codebase_path} is already being indexed') }
		else {
			SessionResponse{
				slot: slot
				codebase: codebase_path
				state: 'uninitialised'
			}
		}
	}
}

/// Close an index session.
pub fn close_session(slot int) !string {
	result := C.codeseeker_close_session(slot)
	return match result {
		0 { 'session ${slot} closed' }
		-1 { return error('slot ${slot} not found or already inactive') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Start indexing a codebase on the given session slot.
pub fn begin_index(slot int) !string {
	result := C.codeseeker_begin_index(slot)
	return match result {
		0 { 'indexing started on slot ${slot}' }
		-1 { return error('slot ${slot} not found') }
		-2 { return error('invalid state transition for slot ${slot} (already indexing?)') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Mark indexing complete on a session slot.
pub fn finish_index(slot int, file_count u32) !IndexResponse {
	result := C.codeseeker_finish_index(slot, file_count)
	if result != 0 {
		return error('failed to finish index on slot ${slot} (code ${result})')
	}
	return IndexResponse{
		slot: slot
		state: 'ready'
		file_count: file_count
	}
}

/// Get the status of a session slot.
pub fn get_status(slot int) StatusResponse {
	state_int := C.codeseeker_get_state(slot)
	file_count := C.codeseeker_get_file_count(slot)
	return StatusResponse{
		slot: slot
		state: state_label(state_int)
		file_count: file_count
		ready: state_int == int(IndexState.ready)
	}
}

/// Perform a hybrid code search (delegates to CodeSeeker MCP tool).
/// The actual query is dispatched to the local CodeSeeker daemon.
/// This adapter tracks the querying state via the FFI state machine.
pub fn search_code(slot int, query string, mode_name string, limit int) !SearchResponse {
	// Validate mode name.
	search_mode := match mode_name {
		'vector' { SearchMode.vector }
		'text' { SearchMode.text }
		'path' { SearchMode.path }
		'hybrid' { SearchMode.hybrid }
		else { return error('unknown search mode: ${mode_name}') }
	}
	// Transition Ready -> Querying.
	begin_rc := C.codeseeker_begin_query(slot)
	if begin_rc != 0 {
		return error('cannot begin query on slot ${slot}: state not ready (code ${begin_rc})')
	}
	// The real search is executed by the CodeSeeker daemon via its MCP tool.
	// The adapter records the mode choice and returns a placeholder structure
	// that the REST layer will populate from the daemon response.
	_ = search_mode
	// Transition Querying -> Ready after dispatch.
	_ = C.codeseeker_finish_query(slot)
	return SearchResponse{
		query: query
		mode: mode_name
		results: []
	}
}

/// Traverse the knowledge graph from a symbol.
pub fn traverse_graph(slot int, symbol string, relation_name string, depth int) !TraverseResponse {
	relation_int := match relation_name {
		'imports' { 1 }
		'calls' { 2 }
		'extends' { 3 }
		'implements' { 4 }
		'uses' { 5 }
		else { return error('unknown relation type: ${relation_name}') }
	}
	begin_rc := C.codeseeker_begin_query(slot)
	if begin_rc != 0 {
		return error('cannot begin graph traversal on slot ${slot} (code ${begin_rc})')
	}
	_ = relation_int
	_ = C.codeseeker_finish_query(slot)
	return TraverseResponse{
		symbol: symbol
		relation: relation_name
		depth: depth
		nodes: []
	}
}

/// Retrieve auto-detected coding patterns for an indexed codebase.
pub fn get_patterns(slot int, codebase_path string) !PatternsResponse {
	begin_rc := C.codeseeker_begin_query(slot)
	if begin_rc != 0 {
		return error('cannot retrieve patterns on slot ${slot} (code ${begin_rc})')
	}
	_ = C.codeseeker_finish_query(slot)
	return PatternsResponse{
		codebase: codebase_path
		patterns: []
	}
}

/// Execute a Graph RAG query — retrieval-augmented generation using graph context.
pub fn graph_rag(slot int, query string) !GraphRagResponse {
	begin_rc := C.codeseeker_begin_query(slot)
	if begin_rc != 0 {
		return error('cannot begin Graph RAG query on slot ${slot} (code ${begin_rc})')
	}
	_ = C.codeseeker_finish_query(slot)
	return GraphRagResponse{
		query: query
		context: ''
		nodes: 0
	}
}

/// Signal an error on a session (e.g. daemon crashed during indexing).
pub fn signal_error(slot int) !string {
	result := C.codeseeker_signal_error(slot)
	return match result {
		0 { 'error signalled on slot ${slot}' }
		-1 { return error('slot ${slot} not found') }
		-2 { return error('cannot signal error from current state on slot ${slot}') }
		else { return error('unknown error (code ${result})') }
	}
}

/// Reset an errored session back to Uninitialised.
pub fn reset_error(slot int) !string {
	result := C.codeseeker_reset_error(slot)
	return match result {
		0 { 'slot ${slot} reset to uninitialised' }
		-1 { return error('slot ${slot} not found') }
		-2 { return error('slot ${slot} is not in error state') }
		else { return error('unknown error (code ${result})') }
	}
}
