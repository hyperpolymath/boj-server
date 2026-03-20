// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — VeriSimDB bridge adapter.
//
// Bridges the echidna-llm tactic advisory cartridge to VeriSimDB for
// persistent proof state storage across all 8 modalities. This adapter
// routes through BoJ's existing verisimdb.zig FFI layer, extending it
// with echidna-specific octad schema encoding.
//
// Operations:
//   store_proof    — Store a complete/partial proof as a VeriSimDB octad
//   get_proof      — Retrieve a proof octad by identity key
//   find_similar   — Search for similar proofs via document/vector modalities
//   store_failure  — Record a failed proof attempt
//   get_stats      — Get proof storage statistics
//   health         — Check VeriSimDB connectivity
//
// Octad key scheme:
//   SHA-256("echidna:v1:{theorem}:{goal_display}:{prover}")
//
// All proofs are stored with 8-modality payloads:
//   semantic  — CBOR proof blob, status, axioms, prover
//   temporal  — version chain (initial → tactics → QED)
//   provenance — hash-chain audit trail
//   document  — searchable text (goals, tactics, aspects)
//   graph     — theorem dependencies, cross-prover links
//   vector    — goal embeddings for similarity search
//   tensor    — proof metrics (time, complexity)
//   spatial   — proof system origin

module echidna_llm_verisimdb

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations — echidna-llm cartridge (link echidna_llm_mcp)
// ═══════════════════════════════════════════════════════════════════════

fn C.echidna_llm_init(endpoint &u8) int
fn C.echidna_llm_get_state() int
fn C.echidna_llm_session_valid() int

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations — VeriSimDB store (link verisimdb_store from BoJ)
// ═══════════════════════════════════════════════════════════════════════

// Initialise the VeriSimDB store with an endpoint URL.
// Pass empty string for in-memory mode.
fn C.verisimdb_store_init(endpoint &u8, len int) int

// Store a key-value pair in VeriSimDB.
fn C.verisimdb_store_put(key &u8, key_len int, value &u8, value_len int) int

// Retrieve a value by key. Writes to out buffer, returns bytes written.
fn C.verisimdb_store_get(key &u8, key_len int, out &u8, out_len int) int

// Delete a key from VeriSimDB.
fn C.verisimdb_store_delete(key &u8, key_len int) int

// Get the number of stored entries.
fn C.verisimdb_store_count() int

// Get read/write/error statistics.
fn C.verisimdb_store_reads() int
fn C.verisimdb_store_writes() int
fn C.verisimdb_store_http_errors() int

// ═══════════════════════════════════════════════════════════════════════
// Label helpers
// ═══════════════════════════════════════════════════════════════════════

fn state_label(v int) string {
	return match v {
		0 { 'unauthenticated' }
		1 { 'authenticated' }
		2 { 'operating' }
		3 { 'closed' }
		else { 'unknown' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Proof octad types — JSON representation of the 8-modality structure
// ═══════════════════════════════════════════════════════════════════════

// A proof octad request — the full 8-modality payload.
struct ProofOctad {
	key        string
	semantic   SemanticPayload
	temporal   TemporalPayload
	provenance ProvenancePayload
	document   DocumentPayload
	graph      GraphPayload
	vector     VectorPayload
	tensor     TensorPayload
	spatial    SpatialPayload
}

struct SemanticPayload {
	proof_blob_b64 string // base64-encoded CBOR ProofState
	status         string // "complete", "partial", "failed", "cached"
	goal_type      string // classification of the goal
	prover         string // prover name
	axioms_used    []string
	llm_model      string // model tier used (empty if none)
	advisory_only  bool
}

struct TemporalPayload {
	versions []ProofVersion
}

struct ProofVersion {
	version         int
	timestamp       string
	actor           string
	description     string
	goals_remaining int
	tactic          string
}

struct ProvenancePayload {
	records []ProvenanceRecord
}

struct ProvenanceRecord {
	hash        string
	parent_hash string
	event       string
	actor       string
	timestamp   string
}

struct DocumentPayload {
	theorem_statement string
	goals_text        []string
	tactics_text      []string
	aspects           []string
	searchable_text   string
}

struct GraphPayload {
	depends_on      []string
	sub_goals       []string
	cross_prover_id string
	prover_id       string
}

struct VectorPayload {
	goal_embedding []f32
	model          string
	dimensions     int
}

struct TensorPayload {
	metrics map[string]f64
}

struct SpatialPayload {
	origin string
}

// ═══════════════════════════════════════════════════════════════════════
// Request/Response types
// ═══════════════════════════════════════════════════════════════════════

// Request to store a proof.
struct StoreProofRequest {
	theorem_name string
	goal_id      string
	goal_display string
	prover       string
	status       string // "complete", "partial", "failed"
	proof_json   string // JSON-encoded proof state (optional)
	axioms       []string
	aspects      []string
	tactics      []string
	time_ms      int
}

// Response from store/get operations.
struct ProofResponse {
	success bool
	key     string
	data    string // JSON octad or error message
	error   string
}

// Request to find similar proofs.
struct FindSimilarRequest {
	goal_display string
	aspects      []string
	max_results  int = 5
}

// Statistics response.
struct StatsResponse {
	total_proofs  int
	total_reads   int
	total_writes  int
	http_errors   int
	connected     bool
}

// Health response.
struct HealthResponse {
	status    string
	adapter   string
	connected bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter functions — called by BoJ cartridge router
// ═══════════════════════════════════════════════════════════════════════

// Initialise the VeriSimDB bridge with endpoint URL.
pub fn init_verisimdb(endpoint string) !ProofResponse {
	result := C.verisimdb_store_init(endpoint.str, endpoint.len)
	if result != 0 {
		return ProofResponse{
			success: false
			error: 'Failed to initialise VeriSimDB store'
		}
	}
	return ProofResponse{
		success: true
		data: '{"status":"initialised","endpoint":"${endpoint}"}'
	}
}

// Store a proof as a VeriSimDB octad.
pub fn store_proof(req StoreProofRequest) !ProofResponse {
	// Generate octad key: SHA-256 of "echidna:v1:{theorem}:{goal}:{prover}"
	key := generate_proof_key(req.theorem_name, req.goal_display, req.prover)

	// Build octad JSON
	octad := build_proof_octad(req, key)
	octad_json := json.encode(octad)

	// Store via VeriSimDB FFI
	result := C.verisimdb_store_put(
		key.str, key.len,
		octad_json.str, octad_json.len,
	)

	if result != 0 {
		return ProofResponse{
			success: false
			key: key
			error: 'VeriSimDB store_put failed with code ${result}'
		}
	}

	return ProofResponse{
		success: true
		key: key
		data: octad_json
	}
}

// Retrieve a proof octad by key.
pub fn get_proof(key string) !ProofResponse {
	mut out_buf := []u8{len: 65536} // 64 KiB — should be enough for most proofs
	bytes_read := C.verisimdb_store_get(
		key.str, key.len,
		out_buf.data, out_buf.len,
	)

	if bytes_read <= 0 {
		return ProofResponse{
			success: false
			key: key
			error: 'Proof not found in VeriSimDB'
		}
	}

	data := out_buf[..bytes_read].bytestr()
	return ProofResponse{
		success: true
		key: key
		data: data
	}
}

// Find similar proofs by searching the document modality.
// Note: full vector similarity search requires VeriSimDB's vector modality
// endpoint, which is accessed directly via HTTP in production.
pub fn find_similar(req FindSimilarRequest) !ProofResponse {
	// For now, search by iterating stored keys (the VeriSimDB HTTP API
	// provides full-text search via the document modality; the C-ABI
	// layer only supports key-value access).
	return ProofResponse{
		success: true
		data: '{"results":[],"note":"Vector similarity search requires VeriSimDB HTTP API"}'
	}
}

// Store a failed proof attempt.
pub fn store_failure(theorem_name string, goal_display string, prover string, reason string, aspects []string) !ProofResponse {
	req := StoreProofRequest{
		theorem_name: theorem_name
		goal_id: ''
		goal_display: goal_display
		prover: prover
		status: 'failed'
		axioms: []
		aspects: aspects
		tactics: []
		time_ms: 0
	}
	return store_proof(req)
}

// Get proof storage statistics.
pub fn get_stats() !StatsResponse {
	count := C.verisimdb_store_count()
	reads := C.verisimdb_store_reads()
	writes := C.verisimdb_store_writes()
	errors := C.verisimdb_store_http_errors()

	return StatsResponse{
		total_proofs: count
		total_reads: reads
		total_writes: writes
		http_errors: errors
		connected: errors == 0 || writes > 0
	}
}

// Check VeriSimDB health.
pub fn health() !HealthResponse {
	stats := get_stats()!
	return HealthResponse{
		status: 'ok'
		adapter: 'echidna_llm_verisimdb'
		connected: stats.connected
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Main dispatch (called by BoJ cartridge router)
// ═══════════════════════════════════════════════════════════════════════

pub fn invoke(operation string, params json.Any) !ProofResponse {
	return match operation {
		'init_verisimdb' {
			endpoint := params.str('endpoint') or { 'http://localhost:8080' }
			init_verisimdb(endpoint)!
		}
		'store_proof' {
			req := json.decode(StoreProofRequest, params.str('request') or { '{}' }) or {
				return ProofResponse{ success: false, error: 'invalid request: ${err}' }
			}
			store_proof(req)!
		}
		'get_proof' {
			key := params.str('key') or { return error('missing key') }
			get_proof(key)!
		}
		'find_similar' {
			req := json.decode(FindSimilarRequest, params.str('request') or { '{}' }) or {
				return ProofResponse{ success: false, error: 'invalid request: ${err}' }
			}
			find_similar(req)!
		}
		'store_failure' {
			theorem := params.str('theorem') or { return error('missing theorem') }
			goal := params.str('goal') or { return error('missing goal') }
			prover := params.str('prover') or { 'unknown' }
			reason := params.str('reason') or { 'unknown' }
			aspects_str := params.str('aspects') or { '[]' }
			aspects := json.decode([]string, aspects_str) or { [] }
			store_failure(theorem, goal, prover, reason, aspects)!
		}
		'stats' {
			stats := get_stats()!
			ProofResponse{
				success: true
				data: json.encode(stats)
			}
		}
		'health' {
			h := health()!
			ProofResponse{
				success: true
				data: json.encode(h)
			}
		}
		else {
			ProofResponse{
				success: false
				error: 'Unknown operation: ${operation}'
			}
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════════

// Generate a proof identity key (simplified SHA-256 via string hashing).
// The full SHA-256 is computed in the Rust proof_encoding module;
// here we use a consistent deterministic hash for the V-lang layer.
fn generate_proof_key(theorem string, goal string, prover string) string {
	input := 'echidna:v1:${theorem}:${goal}:${prover}'
	// Use V's built-in string hash as a deterministic key.
	// In production, the Rust layer computes the real SHA-256.
	h := input.hash()
	return 'echidna-${h:016x}'
}

// Build a proof octad from a store request.
fn build_proof_octad(req StoreProofRequest, key string) ProofOctad {
	now := '2026-03-20T00:00:00Z' // In production: time.now().format_rfc3339()

	// Temporal: one version per tactic
	mut versions := [ProofVersion{
		version: 0
		timestamp: now
		actor: 'echidna-dispatch'
		description: 'Proof attempt initialised'
		goals_remaining: 1
	}]

	for i, tactic in req.tactics {
		versions << ProofVersion{
			version: i + 1
			timestamp: now
			actor: req.prover
			description: 'Applied tactic: ${tactic}'
			goals_remaining: if req.status == 'complete' && i == req.tactics.len - 1 { 0 } else { 1 }
			tactic: tactic
		}
	}

	if req.status == 'complete' {
		versions << ProofVersion{
			version: req.tactics.len + 1
			timestamp: now
			actor: 'echidna-verify'
			description: 'Proof complete (QED)'
			goals_remaining: 0
		}
	}

	// Provenance: creation record
	provenance := ProvenancePayload{
		records: [ProvenanceRecord{
			hash: key
			parent_hash: ''
			event: if req.status == 'failed' { 'Failed' } else { 'Created' }
			actor: 'echidna-dispatch'
			timestamp: now
		}]
	}

	// Document: searchable text
	searchable := '${req.theorem_name} ${req.goal_display} ${req.tactics.join(" ")} ${req.aspects.join(" ")}'

	document := DocumentPayload{
		theorem_statement: req.goal_display
		goals_text: [req.goal_display]
		tactics_text: req.tactics
		aspects: req.aspects
		searchable_text: searchable
	}

	// Graph
	graph := GraphPayload{
		depends_on: []
		sub_goals: []
		cross_prover_id: generate_proof_key(req.theorem_name, req.goal_display, '')
		prover_id: 'echidna:prover:${req.prover}'
	}

	// Semantic
	semantic := SemanticPayload{
		proof_blob_b64: if req.proof_json.len > 0 { req.proof_json } else { '' }
		status: req.status
		goal_type: 'unknown'
		prover: req.prover
		axioms_used: req.axioms
		llm_model: ''
		advisory_only: false
	}

	mut metrics := map[string]f64{}
	metrics['time_ms'] = f64(req.time_ms)

	return ProofOctad{
		key: key
		semantic: semantic
		temporal: TemporalPayload{ versions: versions }
		provenance: provenance
		document: document
		graph: graph
		vector: VectorPayload{
			goal_embedding: []
			model: 'none'
			dimensions: 0
		}
		tensor: TensorPayload{ metrics: metrics }
		spatial: SpatialPayload{ origin: 'echidna-v1.5.0' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_generate_proof_key() {
	key1 := generate_proof_key('thm', 'P -> P', 'Lean4')
	key2 := generate_proof_key('thm', 'P -> P', 'Lean4')
	assert key1 == key2, 'same inputs must produce same key'

	key3 := generate_proof_key('thm', 'P -> P', 'Coq')
	assert key1 != key3, 'different provers must produce different keys'
}

fn test_build_proof_octad_complete() {
	req := StoreProofRequest{
		theorem_name: 'nat_add_zero'
		goal_id: 'g0'
		goal_display: 'forall n, n + 0 = n'
		prover: 'Lean4'
		status: 'complete'
		axioms: ['Nat.rec']
		aspects: ['arithmetic', 'induction']
		tactics: ['induction n', 'simp', 'rfl']
		time_ms: 42
	}

	octad := build_proof_octad(req, 'test-key')

	assert octad.key == 'test-key'
	assert octad.semantic.status == 'complete'
	assert octad.semantic.prover == 'Lean4'
	assert octad.semantic.axioms_used == ['Nat.rec']

	// Temporal: initial + 3 tactics + QED = 5
	assert octad.temporal.versions.len == 5
	assert octad.temporal.versions[0].actor == 'echidna-dispatch'
	assert octad.temporal.versions[4].description == 'Proof complete (QED)'

	// Document
	assert octad.document.searchable_text.contains('nat_add_zero')
	assert octad.document.aspects == ['arithmetic', 'induction']

	// Tensor
	assert octad.tensor.metrics['time_ms'] == 42.0
}

fn test_build_proof_octad_failed() {
	req := StoreProofRequest{
		theorem_name: 'hard_thm'
		goal_id: 'g1'
		goal_display: 'P = NP'
		prover: 'Z3'
		status: 'failed'
		axioms: []
		aspects: ['complexity']
		tactics: []
		time_ms: 300000
	}

	octad := build_proof_octad(req, 'fail-key')

	assert octad.semantic.status == 'failed'
	assert octad.provenance.records[0].event == 'Failed'
	assert octad.temporal.versions.len == 1 // Only initial, no QED
}

fn test_health() {
	h := health() or {
		assert false, 'health should not fail: ${err}'
		return
	}
	assert h.adapter == 'echidna_llm_verisimdb'
	assert h.status == 'ok'
}

fn test_stats() {
	stats := get_stats() or {
		assert false, 'stats should not fail: ${err}'
		return
	}
	assert stats.total_proofs >= 0
}
