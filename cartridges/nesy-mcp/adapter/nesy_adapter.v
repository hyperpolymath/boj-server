// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (nesy_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Exposes the harmonization law: Symbolic truth always overrides
// Neural probability.

module nesy_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against nesy_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.nesy_harmonize(neural int, symbolic int) int
fn C.nesy_confidence(neural int, symbolic int) int

// ═══════════════════════════════════════════════════════════════════════
// Types
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

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct HarmonizeResponse {
	neural_input     string
	symbolic_input   string
	verdict          string
	confidence       string
	symbolic_wins    bool
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions
// ═══════════════════════════════════════════════════════════════════════

pub fn harmonize(neural_verdict string, symbolic_verdict string) !HarmonizeResponse {
	neural := match neural_verdict {
		'probable_safe' { 1 }
		'unsure' { 2 }
		'probable_unsafe' { 3 }
		else { return error('unknown neural verdict: ${neural_verdict}') }
	}
	symbolic := match symbolic_verdict {
		'proven_safe' { 1 }
		'no_proof' { 2 }
		'proven_unsafe' { 3 }
		else { return error('unknown symbolic verdict: ${symbolic_verdict}') }
	}

	result := C.nesy_harmonize(neural, symbolic)
	conf := C.nesy_confidence(neural, symbolic)

	return HarmonizeResponse{
		neural_input: neural_verdict
		symbolic_input: symbolic_verdict
		verdict: harmonized_label(result)
		confidence: confidence_label(conf)
		symbolic_wins: symbolic != 2 // symbolic always wins when there's a proof
	}
}
