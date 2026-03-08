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
// Protocol FFI (v0.2.0 — from proven-nesy)
fn C.nesy_recommend_drift_action(drift int) int
fn C.nesy_mode_uses_symbolic(mode int) int
fn C.nesy_mode_uses_neural(mode int) int
fn C.nesy_grounding_is_trusted(g int) int
fn C.nesy_drift_is_urgent(drift int) int

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

// ═══════════════════════════════════════════════════════════════════════
// Protocol Functions (v0.2.0 — from proven-nesy)
// ═══════════════════════════════════════════════════════════════════════

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

struct DriftReport {
	drift              string
	severity           int
	urgent             bool
	recommended_action string
}

struct ReasoningModeInfo {
	mode           string
	uses_symbolic  bool
	uses_neural    bool
	is_hybrid      bool
}

pub fn analyze_drift(kind string) !DriftReport {
	drift_int := match kind.to_lower() {
		'nodrift', 'no_drift', 'none' { 0 }
		'semanticdrift', 'semantic' { 1 }
		'confidencedrift', 'confidence' { 2 }
		'factualdrift', 'factual' { 3 }
		'temporaldrift', 'temporal' { 4 }
		'catastrophicdrift', 'catastrophic' { 5 }
		else { return error('unknown drift kind: ${kind}') }
	}
	action := C.nesy_recommend_drift_action(drift_int)
	return DriftReport{
		drift: drift_kind_label(drift_int)
		severity: drift_int
		urgent: C.nesy_drift_is_urgent(drift_int) == 1
		recommended_action: drift_action_label(action)
	}
}

pub fn reasoning_mode_info(mode string) !ReasoningModeInfo {
	mode_int := match mode.to_lower() {
		'symbolic' { 0 }
		'neural' { 1 }
		'symtoneural' { 2 }
		'neuraltosym' { 3 }
		'ensemble' { 4 }
		'cascade' { 5 }
		else { return error('unknown reasoning mode: ${mode}') }
	}
	sym := C.nesy_mode_uses_symbolic(mode_int) == 1
	neur := C.nesy_mode_uses_neural(mode_int) == 1
	return ReasoningModeInfo{
		mode: reasoning_mode_label(mode_int)
		uses_symbolic: sym
		uses_neural: neur
		is_hybrid: sym && neur
	}
}
