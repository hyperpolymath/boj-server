// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — SOAP 1.2 transport adapter.
//
// Implements a SOAP 1.2 endpoint for the NeSy harmonization engine.
// Uses XML envelope format with the NeSy namespace. This adapter exists
// for enterprise integration scenarios where SOAP is mandated by policy.
//
// Namespace: http://nesy.hyperpolymath.dev/soap/v1
//
// Operations:
//   HarmonizeRequest  → HarmonizeResponse
//   DriftAnalysis     → DriftAnalysisResponse
//   ReasoningModeInfo → ReasoningModeInfoResponse
//
// Content-Type: application/soap+xml; charset=utf-8
// SOAPAction header is required for each operation.

module nesy_soap

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
// SOAP constants
// ═══════════════════════════════════════════════════════════════════════

// The NeSy SOAP namespace URI used in all envelope elements.
const nesy_namespace = 'http://nesy.hyperpolymath.dev/soap/v1'

// SOAP 1.2 envelope namespace.
const soap_env_namespace = 'http://www.w3.org/2003/05/soap-envelope'

// Content-Type header value for SOAP 1.2 responses.
const soap_content_type = 'application/soap+xml; charset=utf-8'

// SOAPAction URIs for each operation.
const action_harmonize = '${nesy_namespace}/Harmonize'
const action_drift = '${nesy_namespace}/DriftAnalysis'
const action_mode = '${nesy_namespace}/ReasoningModeInfo'

// ═══════════════════════════════════════════════════════════════════════
// SOAP Envelope builder — constructs well-formed SOAP 1.2 XML
// ═══════════════════════════════════════════════════════════════════════

// Build a complete SOAP 1.2 envelope wrapping the given body XML.
// The body should contain NeSy-namespaced elements.
fn build_envelope(body string) string {
	return '<?xml version="1.0" encoding="UTF-8"?>\n' +
		'<soap:Envelope xmlns:soap="${soap_env_namespace}" xmlns:nesy="${nesy_namespace}">\n' +
		'  <soap:Header/>\n' +
		'  <soap:Body>\n' +
		'${body}\n' +
		'  </soap:Body>\n' +
		'</soap:Envelope>'
}

// Build a SOAP 1.2 Fault envelope for error responses.
// Follows the SOAP 1.2 fault structure with Code/Reason/Detail.
fn build_fault(code string, reason string, detail string) string {
	body := '    <soap:Fault>\n' +
		'      <soap:Code>\n' +
		'        <soap:Value>soap:Sender</soap:Value>\n' +
		'        <soap:Subcode>\n' +
		'          <soap:Value>nesy:${code}</soap:Value>\n' +
		'        </soap:Subcode>\n' +
		'      </soap:Code>\n' +
		'      <soap:Reason>\n' +
		'        <soap:Text xml:lang="en">${reason}</soap:Text>\n' +
		'      </soap:Reason>\n' +
		'      <soap:Detail>\n' +
		'        <nesy:ErrorDetail>${detail}</nesy:ErrorDetail>\n' +
		'      </soap:Detail>\n' +
		'    </soap:Fault>'
	return build_envelope(body)
}

// ═══════════════════════════════════════════════════════════════════════
// XML element helpers — build NeSy-namespaced elements
// ═══════════════════════════════════════════════════════════════════════

// Build a single XML element with text content inside the NeSy namespace.
fn nesy_element(tag string, value string) string {
	return '      <nesy:${tag}>${value}</nesy:${tag}>'
}

// Build a boolean XML element (serialised as "true"/"false").
fn nesy_bool_element(tag string, value bool) string {
	return nesy_element(tag, if value { 'true' } else { 'false' })
}

// Build an integer XML element.
fn nesy_int_element(tag string, value int) string {
	return nesy_element(tag, '${value}')
}

// ═══════════════════════════════════════════════════════════════════════
// Operation: HarmonizeRequest → HarmonizeResponse
// ═══════════════════════════════════════════════════════════════════════

// Build the SOAP response for a Harmonize operation.
// Takes the neural and symbolic verdict labels, calls the FFI, and
// returns the complete SOAP envelope XML.
pub fn harmonize_response(neural_str string, symbolic_str string) !string {
	neural := parse_neural(neural_str)!
	symbolic := parse_symbolic(symbolic_str)!

	result := C.nesy_harmonize(neural, symbolic)
	conf := C.nesy_confidence(neural, symbolic)

	body := '    <nesy:HarmonizeResponse>\n' +
		nesy_element('NeuralInput', neural_label(neural)) + '\n' +
		nesy_element('SymbolicInput', symbolic_label(symbolic)) + '\n' +
		nesy_element('Verdict', harmonized_label(result)) + '\n' +
		nesy_element('Confidence', confidence_label(conf)) + '\n' +
		nesy_bool_element('SymbolicWins', symbolic != 2) + '\n' +
		'    </nesy:HarmonizeResponse>'
	return build_envelope(body)
}

// ═══════════════════════════════════════════════════════════════════════
// Operation: DriftAnalysis → DriftAnalysisResponse
// ═══════════════════════════════════════════════════════════════════════

// Build the SOAP response for a DriftAnalysis operation.
// Takes a drift kind label, calls the FFI, and returns the envelope.
pub fn drift_analysis_response(kind string) !string {
	drift_int := parse_drift(kind)!
	action := C.nesy_recommend_drift_action(drift_int)

	body := '    <nesy:DriftAnalysisResponse>\n' +
		nesy_element('Drift', drift_kind_label(drift_int)) + '\n' +
		nesy_int_element('Severity', drift_int) + '\n' +
		nesy_bool_element('Urgent', C.nesy_drift_is_urgent(drift_int) == 1) + '\n' +
		nesy_element('RecommendedAction', drift_action_label(action)) + '\n' +
		'    </nesy:DriftAnalysisResponse>'
	return build_envelope(body)
}

// ═══════════════════════════════════════════════════════════════════════
// Operation: ReasoningModeInfo → ReasoningModeInfoResponse
// ═══════════════════════════════════════════════════════════════════════

// Build the SOAP response for a ReasoningModeInfo operation.
// Takes a mode label, calls the FFI, and returns the envelope.
pub fn reasoning_mode_info_response(mode string) !string {
	mode_int := parse_mode(mode)!
	sym := C.nesy_mode_uses_symbolic(mode_int) == 1
	neur := C.nesy_mode_uses_neural(mode_int) == 1

	body := '    <nesy:ReasoningModeInfoResponse>\n' +
		nesy_element('Mode', reasoning_mode_label(mode_int)) + '\n' +
		nesy_bool_element('UsesSymbolic', sym) + '\n' +
		nesy_bool_element('UsesNeural', neur) + '\n' +
		nesy_bool_element('IsHybrid', sym && neur) + '\n' +
		'    </nesy:ReasoningModeInfoResponse>'
	return build_envelope(body)
}

// ═══════════════════════════════════════════════════════════════════════
// Request dispatcher — routes incoming SOAP envelopes by SOAPAction
// ═══════════════════════════════════════════════════════════════════════

// Minimal parsed representation of an inbound SOAP request.
// In production, a full XML parser extracts these from the envelope.
pub struct SoapRequest {
pub:
	soap_action string // SOAPAction header value
	param1      string // first operation parameter
	param2      string // second operation parameter (if applicable)
}

// Dispatch a SOAP request by its SOAPAction header and return the
// SOAP response envelope XML. Returns a SOAP Fault for unknown actions.
pub fn dispatch(req SoapRequest) string {
	match req.soap_action {
		action_harmonize {
			return harmonize_response(req.param1, req.param2) or {
				return build_fault('InvalidInput', 'Harmonize failed', err.msg())
			}
		}
		action_drift {
			return drift_analysis_response(req.param1) or {
				return build_fault('InvalidInput', 'DriftAnalysis failed', err.msg())
			}
		}
		action_mode {
			return reasoning_mode_info_response(req.param1) or {
				return build_fault('InvalidInput', 'ReasoningModeInfo failed', err.msg())
			}
		}
		else {
			return build_fault('UnknownOperation',
				'Unknown SOAPAction',
				'SOAPAction "${req.soap_action}" is not recognised. ' +
				'Valid actions: ${action_harmonize}, ${action_drift}, ${action_mode}')
		}
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

// Verify that a HarmonizeResponse SOAP envelope is well-formed and
// contains the expected NeSy-namespaced elements.
fn test_soap_harmonize() {
	result := harmonize_response('unsure', 'proven_safe') or {
		assert false, 'harmonize_response failed: ${err}'
		return
	}
	assert result.contains('soap:Envelope')
	assert result.contains('nesy:HarmonizeResponse')
	assert result.contains('nesy:Verdict')
	assert result.contains('nesy:Confidence')
	assert result.contains('nesy:SymbolicWins')
	assert result.contains(nesy_namespace)
}

// Verify that a DriftAnalysisResponse contains severity and urgency.
fn test_soap_drift() {
	result := drift_analysis_response('catastrophic') or {
		assert false, 'drift_analysis_response failed: ${err}'
		return
	}
	assert result.contains('nesy:DriftAnalysisResponse')
	assert result.contains('CatastrophicDrift')
	assert result.contains('nesy:Urgent')
	assert result.contains('nesy:Severity')
}

// Verify that a ReasoningModeInfoResponse contains hybrid status.
fn test_soap_mode() {
	result := reasoning_mode_info_response('ensemble') or {
		assert false, 'reasoning_mode_info_response failed: ${err}'
		return
	}
	assert result.contains('nesy:ReasoningModeInfoResponse')
	assert result.contains('Ensemble')
	assert result.contains('nesy:IsHybrid')
}

// Verify that an unknown SOAPAction returns a SOAP Fault.
fn test_soap_unknown_action() {
	req := SoapRequest{
		soap_action: 'http://example.com/Explode'
		param1: ''
	}
	result := dispatch(req)
	assert result.contains('soap:Fault')
	assert result.contains('UnknownOperation')
}

// Verify that invalid input to Harmonize returns a SOAP Fault
// with the InvalidInput subcode.
fn test_soap_invalid_input_fault() {
	req := SoapRequest{
		soap_action: action_harmonize
		param1: 'banana'
		param2: 'proven_safe'
	}
	result := dispatch(req)
	assert result.contains('soap:Fault')
	assert result.contains('InvalidInput')
	assert result.contains('unknown neural verdict')
}

// Verify that the SOAP envelope builder produces valid XML structure.
fn test_soap_envelope_structure() {
	envelope := build_envelope('    <nesy:Test>hello</nesy:Test>')
	assert envelope.starts_with('<?xml version="1.0"')
	assert envelope.contains('soap:Envelope')
	assert envelope.contains('soap:Header')
	assert envelope.contains('soap:Body')
	assert envelope.contains('nesy:Test')
	assert envelope.contains('</soap:Envelope>')
}
