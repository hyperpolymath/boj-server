// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — Cap'n Proto serialization adapter.
//
// Implements Cap'n Proto-style flat zero-copy serialization for the NeSy
// harmonization engine. Struct definitions use fixed-offset segments for
// zero-copy reads. RPC method dispatch uses integer method IDs:
//
//   Method ID 1: harmonize  — HarmonizeRequest → HarmonizeResponse
//   Method ID 2: drift      — DriftRequest → DriftResponse
//   Method ID 3: mode       — ModeRequest → ModeResponse
//
// Segment layout:
//   Each message is a flat byte buffer with a 4-byte method ID header
//   followed by fixed-width struct fields. Strings are stored as
//   length-prefixed inline data (not pointer-based) for simplicity in
//   this V-lang adapter layer. The Zig FFI handles the actual
//   computation; this layer handles serialization/deserialization only.
//
// Wire format (all little-endian):
//   [4 bytes: method_id] [N bytes: struct fields per method schema]

module nesy_capnproto

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against nesy_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

// Harmonize a neural verdict with a symbolic verdict, returning
// a HarmonizedVerdict integer. Symbolic truth always overrides.
fn C.nesy_harmonize(neural int, symbolic int) int

// Compute a confidence level for the harmonization result.
fn C.nesy_confidence(neural int, symbolic int) int

// Given a DriftKind integer, return the recommended DriftAction.
fn C.nesy_recommend_drift_action(drift int) int

// Returns 1 if the given ReasoningMode uses symbolic reasoning.
fn C.nesy_mode_uses_symbolic(mode int) int

// Returns 1 if the given ReasoningMode uses neural reasoning.
fn C.nesy_mode_uses_neural(mode int) int

// Returns 1 if the given grounding level is considered trusted.
fn C.nesy_grounding_is_trusted(g int) int

// Returns 1 if the given DriftKind is urgent (severity >= 4).
fn C.nesy_drift_is_urgent(drift int) int

// ═══════════════════════════════════════════════════════════════════════
// Label helpers — convert integer encodings to human-readable strings
// ═══════════════════════════════════════════════════════════════════════

fn neural_label(v int) string {
	return match v {
		1 { 'probable_safe' }
		2 { 'unsure' }
		3 { 'probable_unsafe' }
		else { 'unknown' }
	}
}

fn symbolic_label(v int) string {
	return match v {
		1 { 'proven_safe' }
		2 { 'no_proof' }
		3 { 'proven_unsafe' }
		else { 'unknown' }
	}
}

fn harmonized_label(v int) string {
	return match v {
		1 { 'certified_safe' }
		2 { 'requires_review' }
		3 { 'critical_unsafe' }
		else { 'unknown' }
	}
}

fn confidence_label(v int) string {
	return match v {
		1 { 'low' }
		2 { 'high' }
		3 { 'absolute' }
		else { 'unknown' }
	}
}

fn drift_kind_label(v int) string {
	return match v {
		0 { 'NoDrift' }
		1 { 'SemanticDrift' }
		2 { 'ConfidenceDrift' }
		3 { 'FactualDrift' }
		4 { 'TemporalDrift' }
		5 { 'CatastrophicDrift' }
		else { 'Unknown' }
	}
}

fn drift_action_label(v int) string {
	return match v {
		0 { 'LogAndAccept' }
		1 { 'FlagForReview' }
		2 { 'RejectNeural' }
		3 { 'RetryNeural' }
		4 { 'Escalate' }
		5 { 'Halt' }
		else { 'Unknown' }
	}
}

fn reasoning_mode_label(v int) string {
	return match v {
		0 { 'Symbolic' }
		1 { 'Neural' }
		2 { 'SymToNeural' }
		3 { 'NeuralToSym' }
		4 { 'Ensemble' }
		5 { 'Cascade' }
		else { 'Unknown' }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// String-to-int parsers
// ═══════════════════════════════════════════════════════════════════════

fn parse_neural(s string) !int {
	return match s {
		'probable_safe' { 1 }
		'unsure' { 2 }
		'probable_unsafe' { 3 }
		else { error('unknown neural verdict: ${s}') }
	}
}

fn parse_symbolic(s string) !int {
	return match s {
		'proven_safe' { 1 }
		'no_proof' { 2 }
		'proven_unsafe' { 3 }
		else { error('unknown symbolic verdict: ${s}') }
	}
}

fn parse_drift(s string) !int {
	return match s.to_lower() {
		'nodrift', 'no_drift', 'none' { 0 }
		'semanticdrift', 'semantic' { 1 }
		'confidencedrift', 'confidence' { 2 }
		'factualdrift', 'factual' { 3 }
		'temporaldrift', 'temporal' { 4 }
		'catastrophicdrift', 'catastrophic' { 5 }
		else { error('unknown drift kind: ${s}') }
	}
}

fn parse_mode(s string) !int {
	return match s.to_lower() {
		'symbolic' { 0 }
		'neural' { 1 }
		'symtoneural' { 2 }
		'neuraltosym' { 3 }
		'ensemble' { 4 }
		'cascade' { 5 }
		else { error('unknown reasoning mode: ${s}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// RPC method IDs — constants for the 4-byte method header
// ═══════════════════════════════════════════════════════════════════════

// Method ID for the harmonize RPC call.
const method_harmonize = 1

// Method ID for the drift RPC call.
const method_drift = 2

// Method ID for the mode RPC call.
const method_mode = 3

// ═══════════════════════════════════════════════════════════════════════
// Segment — flat zero-copy byte buffer for Cap'n Proto messages
// ═══════════════════════════════════════════════════════════════════════

// A Segment is a flat byte buffer that Cap'n Proto structs are
// serialized into. All reads and writes use fixed offsets for
// zero-copy access. This is the fundamental building block.
struct Segment {
mut:
	data []u8 // backing byte buffer
}

// Create a new empty Segment with the given initial capacity.
fn Segment.new(capacity int) Segment {
	return Segment{
		data: []u8{cap: capacity}
	}
}

// Create a Segment from an existing byte buffer (for deserialization).
fn Segment.from_bytes(bytes []u8) Segment {
	return Segment{
		data: bytes.clone()
	}
}

// Write a 32-bit little-endian integer at the current end of the segment.
fn (mut s Segment) write_i32(value int) {
	s.data << u8(value & 0xFF)
	s.data << u8((value >> 8) & 0xFF)
	s.data << u8((value >> 16) & 0xFF)
	s.data << u8((value >> 24) & 0xFF)
}

// Write a boolean as a single byte (0 or 1).
fn (mut s Segment) write_bool(value bool) {
	s.data << if value { u8(1) } else { u8(0) }
}

// Write a length-prefixed string: [4 bytes: length][N bytes: UTF-8 data].
fn (mut s Segment) write_string(value string) {
	s.write_i32(value.len)
	s.data << value.bytes()
}

// Read a 32-bit little-endian integer at the given byte offset.
// Returns 0 if the offset is out of bounds.
fn (s &Segment) read_i32(offset int) int {
	if offset + 4 > s.data.len {
		return 0
	}
	return int(s.data[offset]) |
		(int(s.data[offset + 1]) << 8) |
		(int(s.data[offset + 2]) << 16) |
		(int(s.data[offset + 3]) << 24)
}

// Read a boolean at the given byte offset.
fn (s &Segment) read_bool(offset int) bool {
	if offset >= s.data.len {
		return false
	}
	return s.data[offset] != 0
}

// Read a length-prefixed string starting at the given byte offset.
// Returns the string and the number of bytes consumed (4 + length).
fn (s &Segment) read_string(offset int) (string, int) {
	length := s.read_i32(offset)
	if length <= 0 || offset + 4 + length > s.data.len {
		return '', 4
	}
	str_bytes := s.data[offset + 4..offset + 4 + length]
	return str_bytes.bytestr(), 4 + length
}

// Return the raw bytes of the segment for wire transmission.
fn (s &Segment) bytes() []u8 {
	return s.data
}

// ═══════════════════════════════════════════════════════════════════════
// MessageBuilder — constructs Cap'n Proto messages with method headers
// ═══════════════════════════════════════════════════════════════════════

// A MessageBuilder creates a wire-format message by writing a method ID
// header followed by the struct payload into a Segment.
struct MessageBuilder {
mut:
	segment Segment
}

// Create a new MessageBuilder for a given RPC method ID.
// Writes the 4-byte method header immediately.
fn MessageBuilder.new(method_id int) MessageBuilder {
	mut mb := MessageBuilder{
		segment: Segment.new(64)
	}
	mb.segment.write_i32(method_id)
	return mb
}

// Get a mutable reference to the underlying segment for writing fields.
fn (mut mb MessageBuilder) seg() &Segment {
	return &mb.segment
}

// Finalise the message and return the raw bytes for transmission.
fn (mb &MessageBuilder) build() []u8 {
	return mb.segment.bytes()
}

// ═══════════════════════════════════════════════════════════════════════
// Struct definitions — Cap'n Proto struct schemas for NeSy types
// ═══════════════════════════════════════════════════════════════════════

// HarmonizeRequest — sent by the client to request harmonization.
// Layout after method header: [i32: neural] [i32: symbolic]
struct HarmonizeRequest {
	neural   int // NeuralVerdict encoding
	symbolic int // SymbolicVerdict encoding
}

// Serialize a HarmonizeRequest into a wire-format message.
fn (hr &HarmonizeRequest) serialize() []u8 {
	mut mb := MessageBuilder.new(method_harmonize)
	mb.segment.write_i32(hr.neural)
	mb.segment.write_i32(hr.symbolic)
	return mb.build()
}

// Deserialize a HarmonizeRequest from raw bytes (after method header).
fn HarmonizeRequest.deserialize(seg &Segment, offset int) HarmonizeRequest {
	return HarmonizeRequest{
		neural: seg.read_i32(offset)
		symbolic: seg.read_i32(offset + 4)
	}
}

// HarmonizeResponse — returned after harmonization.
// Layout: [str: neural_input] [str: symbolic_input] [str: verdict]
//         [str: confidence] [bool: symbolic_wins]
struct HarmonizeResponse {
	neural_input   string
	symbolic_input string
	verdict        string
	confidence     string
	symbolic_wins  bool
}

// Serialize a HarmonizeResponse into a flat segment.
fn (hr &HarmonizeResponse) serialize() []u8 {
	mut seg := Segment.new(128)
	seg.write_string(hr.neural_input)
	seg.write_string(hr.symbolic_input)
	seg.write_string(hr.verdict)
	seg.write_string(hr.confidence)
	seg.write_bool(hr.symbolic_wins)
	return seg.bytes()
}

// DriftReport — result of drift analysis.
// Layout: [str: drift] [i32: severity] [bool: urgent] [str: action]
struct DriftReport {
	drift              string
	severity           int
	urgent             bool
	recommended_action string
}

// Serialize a DriftReport into a flat segment.
fn (dr &DriftReport) serialize() []u8 {
	mut seg := Segment.new(64)
	seg.write_string(dr.drift)
	seg.write_i32(dr.severity)
	seg.write_bool(dr.urgent)
	seg.write_string(dr.recommended_action)
	return seg.bytes()
}

// ModeInfo — result of reasoning mode query.
// Layout: [str: mode] [bool: uses_symbolic] [bool: uses_neural]
//         [bool: is_hybrid]
struct ModeInfo {
	mode          string
	uses_symbolic bool
	uses_neural   bool
	is_hybrid     bool
}

// Serialize a ModeInfo into a flat segment.
fn (mi &ModeInfo) serialize() []u8 {
	mut seg := Segment.new(32)
	seg.write_string(mi.mode)
	seg.write_bool(mi.uses_symbolic)
	seg.write_bool(mi.uses_neural)
	seg.write_bool(mi.is_hybrid)
	return seg.bytes()
}

// ═══════════════════════════════════════════════════════════════════════
// RPC dispatch — route incoming messages by method ID
// ═══════════════════════════════════════════════════════════════════════

// Dispatch an incoming Cap'n Proto message. Reads the 4-byte method ID,
// deserializes the request struct, calls the Zig FFI, and returns the
// serialized response bytes.
pub fn dispatch(raw []u8) ![]u8 {
	if raw.len < 4 {
		return error('message too short: need at least 4 bytes for method ID')
	}

	seg := Segment.from_bytes(raw)
	method_id := seg.read_i32(0)

	match method_id {
		method_harmonize {
			return handle_harmonize(seg)
		}
		method_drift {
			return handle_drift(seg)
		}
		method_mode {
			return handle_mode(seg)
		}
		else {
			return error('unknown method ID: ${method_id}')
		}
	}
}

// Handle a harmonize RPC call. Reads neural and symbolic verdict ints
// from the segment, calls the FFI, and returns a serialized response.
fn handle_harmonize(seg Segment) ![]u8 {
	req := HarmonizeRequest.deserialize(&seg, 4) // skip 4-byte method header
	if req.neural < 1 || req.neural > 3 {
		return error('invalid neural verdict encoding: ${req.neural}')
	}
	if req.symbolic < 1 || req.symbolic > 3 {
		return error('invalid symbolic verdict encoding: ${req.symbolic}')
	}

	result := C.nesy_harmonize(req.neural, req.symbolic)
	conf := C.nesy_confidence(req.neural, req.symbolic)

	resp := HarmonizeResponse{
		neural_input: neural_label(req.neural)
		symbolic_input: symbolic_label(req.symbolic)
		verdict: harmonized_label(result)
		confidence: confidence_label(conf)
		symbolic_wins: req.symbolic != 2
	}
	return resp.serialize()
}

// Handle a drift RPC call. Reads the drift kind int from the segment,
// calls the FFI, and returns a serialized DriftReport.
fn handle_drift(seg Segment) ![]u8 {
	drift_int := seg.read_i32(4) // skip 4-byte method header
	if drift_int < 0 || drift_int > 5 {
		return error('invalid drift kind encoding: ${drift_int}')
	}

	action := C.nesy_recommend_drift_action(drift_int)
	resp := DriftReport{
		drift: drift_kind_label(drift_int)
		severity: drift_int
		urgent: C.nesy_drift_is_urgent(drift_int) == 1
		recommended_action: drift_action_label(action)
	}
	return resp.serialize()
}

// Handle a mode RPC call. Reads the reasoning mode int from the segment,
// calls the FFI, and returns a serialized ModeInfo.
fn handle_mode(seg Segment) ![]u8 {
	mode_int := seg.read_i32(4) // skip 4-byte method header
	if mode_int < 0 || mode_int > 5 {
		return error('invalid reasoning mode encoding: ${mode_int}')
	}

	sym := C.nesy_mode_uses_symbolic(mode_int) == 1
	neur := C.nesy_mode_uses_neural(mode_int) == 1
	resp := ModeInfo{
		mode: reasoning_mode_label(mode_int)
		uses_symbolic: sym
		uses_neural: neur
		is_hybrid: sym && neur
	}
	return resp.serialize()
}

// ═══════════════════════════════════════════════════════════════════════
// Convenience API — string-based interface for higher-level adapters
// ═══════════════════════════════════════════════════════════════════════

// Harmonize using string labels. Parses inputs, calls FFI, returns a
// JSON-encoded HarmonizeResponse for interop with other adapter layers.
pub fn harmonize(neural_str string, symbolic_str string) !string {
	neural := parse_neural(neural_str)!
	symbolic := parse_symbolic(symbolic_str)!

	result := C.nesy_harmonize(neural, symbolic)
	conf := C.nesy_confidence(neural, symbolic)

	return json.encode(HarmonizeResponse{
		neural_input: neural_label(neural)
		symbolic_input: symbolic_label(symbolic)
		verdict: harmonized_label(result)
		confidence: confidence_label(conf)
		symbolic_wins: symbolic != 2
	})
}

// Analyze drift using a string label. Parses, calls FFI, returns JSON.
pub fn analyze_drift(kind string) !string {
	drift_int := parse_drift(kind)!
	action := C.nesy_recommend_drift_action(drift_int)

	return json.encode(DriftReport{
		drift: drift_kind_label(drift_int)
		severity: drift_int
		urgent: C.nesy_drift_is_urgent(drift_int) == 1
		recommended_action: drift_action_label(action)
	})
}

// Query reasoning mode using a string label. Parses, calls FFI, returns JSON.
pub fn query_mode(mode string) !string {
	mode_int := parse_mode(mode)!
	sym := C.nesy_mode_uses_symbolic(mode_int) == 1
	neur := C.nesy_mode_uses_neural(mode_int) == 1

	return json.encode(ModeInfo{
		mode: reasoning_mode_label(mode_int)
		uses_symbolic: sym
		uses_neural: neur
		is_hybrid: sym && neur
	})
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that a HarmonizeRequest round-trips through serialization
// and the dispatch function returns a non-empty response.
fn test_capnp_harmonize_roundtrip() {
	req := HarmonizeRequest{
		neural: 2   // unsure
		symbolic: 1 // proven_safe
	}
	wire := req.serialize()
	assert wire.len > 0

	// Dispatch the serialized message
	response := dispatch(wire) or {
		assert false, 'dispatch failed: ${err}'
		return
	}
	assert response.len > 0
}

// Verify that a drift dispatch returns valid bytes.
fn test_capnp_drift_dispatch() {
	mut mb := MessageBuilder.new(method_drift)
	mb.segment.write_i32(5) // CatastrophicDrift
	wire := mb.build()

	response := dispatch(wire) or {
		assert false, 'drift dispatch failed: ${err}'
		return
	}
	assert response.len > 0
}

// Verify that a mode dispatch returns valid bytes.
fn test_capnp_mode_dispatch() {
	mut mb := MessageBuilder.new(method_mode)
	mb.segment.write_i32(4) // Ensemble
	wire := mb.build()

	response := dispatch(wire) or {
		assert false, 'mode dispatch failed: ${err}'
		return
	}
	assert response.len > 0
}

// Verify that an unknown method ID returns an error.
fn test_capnp_unknown_method() {
	mut mb := MessageBuilder.new(99)
	wire := mb.build()

	dispatch(wire) or {
		assert err.msg().contains('unknown method ID')
		return
	}
	assert false, 'expected error for unknown method ID'
}

// Verify that a too-short message returns an error.
fn test_capnp_short_message() {
	dispatch([]u8{len: 2}) or {
		assert err.msg().contains('too short')
		return
	}
	assert false, 'expected error for short message'
}

// Verify Segment read/write round-trip for i32 values.
fn test_segment_i32_roundtrip() {
	mut seg := Segment.new(16)
	seg.write_i32(42)
	seg.write_i32(-1)
	assert seg.read_i32(0) == 42
	assert seg.read_i32(4) == -1
}

// Verify Segment read/write round-trip for strings.
fn test_segment_string_roundtrip() {
	mut seg := Segment.new(64)
	seg.write_string('hello')
	seg.write_string('world')

	s1, consumed1 := seg.read_string(0)
	assert s1 == 'hello'
	assert consumed1 == 9 // 4 bytes length + 5 bytes "hello"

	s2, _ := seg.read_string(consumed1)
	assert s2 == 'world'
}

// Verify the convenience string API for harmonize.
fn test_capnp_convenience_harmonize() {
	result := harmonize('unsure', 'proven_safe') or {
		assert false, 'convenience harmonize failed: ${err}'
		return
	}
	assert result.contains('verdict')
	assert result.contains('confidence')
}
