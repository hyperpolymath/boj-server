// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// echidna-llm-mcp Cartridge — SOAP 1.2 transport adapter.
//
// Implements a SOAP 1.2 server for the ECHIDNA frontier LLM tactic
// advisory. SOAP provides enterprise-grade XML-based web services with
// WSDL-describable interfaces, suitable for government and institutional
// integrations where XML-over-HTTP is mandated.
//
// Operations (WSDL-equivalent):
//   SuggestTactics    — request tactic suggestions for a proof goal
//   RankProvers       — request prover ranking for a goal
//   Authenticate      — create ephemeral session
//   GetStatus         — get current session state
//   CloseSession      — close current session
//   Health            — adapter health check
//
// SOAP Action header:
//   SOAPAction: "urn:echidna-llm:SuggestTactics"
//
// Namespace: urn:echidna-llm:v1

module echidna_llm_soap

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against echidna_llm_mcp built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.echidna_llm_init(endpoint &u8) int
fn C.echidna_llm_authenticate(token &u8, token_len int, max_calls int, expiry_ms int) int
fn C.echidna_llm_start_operating() int
fn C.echidna_llm_close() int
fn C.echidna_llm_get_state() int
fn C.echidna_llm_session_valid() int
fn C.echidna_llm_suggest_tactics(goal &u8, goal_len int, hyp &u8, hyp_len int, prover_id int, top_k int, model int) &u8
fn C.echidna_llm_rank_provers(goal &u8, goal_len int, model int) &u8
fn C.echidna_llm_free(ptr &u8)
fn C.echidna_llm_can_transition(from int, to int) int
fn C.echidna_llm_is_advisory(op int) int

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

fn model_from_string(s string) int {
	return match s {
		'haiku' { 0 }
		'opus' { 2 }
		else { 1 }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// SOAP constants
// ═══════════════════════════════════════════════════════════════════════

const soap_ns = 'urn:echidna-llm:v1'
const soap_env_ns = 'http://www.w3.org/2003/05/soap-envelope'

// SOAP Action URN for each operation.
const action_suggest = 'urn:echidna-llm:SuggestTactics'
const action_rank = 'urn:echidna-llm:RankProvers'
const action_auth = 'urn:echidna-llm:Authenticate'
const action_status = 'urn:echidna-llm:GetStatus'
const action_close = 'urn:echidna-llm:CloseSession'
const action_health = 'urn:echidna-llm:Health'

// ═══════════════════════════════════════════════════════════════════════
// SOAP envelope construction
// ═══════════════════════════════════════════════════════════════════════

// Wrap a body XML string in a SOAP 1.2 envelope.
pub fn wrap_envelope(body string) string {
	return '<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="${soap_env_ns}" xmlns:ech="${soap_ns}">
  <soap:Body>
${body}
  </soap:Body>
</soap:Envelope>'
}

// Format a SOAP Fault response.
pub fn soap_fault(code string, reason string) string {
	return wrap_envelope('    <soap:Fault>
      <soap:Code>
        <soap:Value>soap:${code}</soap:Value>
      </soap:Code>
      <soap:Reason>
        <soap:Text xml:lang="en">${reason}</soap:Text>
      </soap:Reason>
    </soap:Fault>')
}

// ═══════════════════════════════════════════════════════════════════════
// Simple XML extraction — pull values from SOAP body elements
// ═══════════════════════════════════════════════════════════════════════

// Extract the text content of a simple XML element by tag name.
// This handles <tag>content</tag> patterns. For production, a full
// XML parser should be used; this is sufficient for the flat SOAP
// bodies in this adapter.
fn extract_xml_value(xml string, tag string) string {
	open_tag := '<ech:${tag}>'
	close_tag := '</ech:${tag}>'
	start := xml.index(open_tag) or { return '' }
	after_open := start + open_tag.len
	end := xml.index_after(close_tag, after_open) or { return '' }
	return xml[after_open..end]
}

// Extract an integer value from an XML element.
fn extract_xml_int(xml string, tag string, default_val int) int {
	val := extract_xml_value(xml, tag)
	if val.len == 0 {
		return default_val
	}
	return val.int()
}

// ═══════════════════════════════════════════════════════════════════════
// Operation dispatcher — routes SOAP actions to handlers
// ═══════════════════════════════════════════════════════════════════════

// Dispatch a SOAP request based on the SOAPAction header and XML body.
// Returns the complete SOAP response envelope.
pub fn dispatch(soap_action string, body string) string {
	return match soap_action {
		action_suggest { handle_suggest_tactics(body) }
		action_rank { handle_rank_provers(body) }
		action_auth { handle_authenticate(body) }
		action_status { handle_status() }
		action_close { handle_close() }
		action_health { handle_health() }
		else { soap_fault('Client', 'unknown SOAPAction: ${soap_action}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// Operation handlers — each extracts XML params, calls FFI, returns XML
// ═══════════════════════════════════════════════════════════════════════

fn handle_suggest_tactics(body string) string {
	goal := extract_xml_value(body, 'Goal')
	hypotheses := extract_xml_value(body, 'Hypotheses')
	prover_id := extract_xml_int(body, 'ProverId', 0)
	top_k := extract_xml_int(body, 'TopK', 10)
	model_str := extract_xml_value(body, 'Model')

	if goal.len == 0 {
		return soap_fault('Client', 'missing required element: Goal')
	}

	if C.echidna_llm_session_valid() != 1 {
		return soap_fault('Client', 'session expired or call limit reached')
	}

	model := model_from_string(if model_str.len > 0 { model_str } else { 'sonnet' })
	hyp := if hypotheses.len > 0 { hypotheses } else { '[]' }

	result_ptr := C.echidna_llm_suggest_tactics(
		goal.str, goal.len,
		hyp.str, hyp.len,
		prover_id, top_k, model,
	)

	if result_ptr == unsafe { nil } {
		return soap_fault('Server', 'tactic suggestion failed — session may have expired')
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return wrap_envelope('    <ech:SuggestTacticsResponse>
      <ech:Success>true</ech:Success>
      <ech:Data>${result_str}</ech:Data>
    </ech:SuggestTacticsResponse>')
}

fn handle_rank_provers(body string) string {
	goal := extract_xml_value(body, 'Goal')
	model_str := extract_xml_value(body, 'Model')

	if goal.len == 0 {
		return soap_fault('Client', 'missing required element: Goal')
	}

	if C.echidna_llm_session_valid() != 1 {
		return soap_fault('Client', 'session expired or call limit reached')
	}

	model := model_from_string(if model_str.len > 0 { model_str } else { 'sonnet' })
	result_ptr := C.echidna_llm_rank_provers(goal.str, goal.len, model)

	if result_ptr == unsafe { nil } {
		return soap_fault('Server', 'prover ranking failed')
	}

	result_str := unsafe { cstring_to_vstring(result_ptr) }
	C.echidna_llm_free(result_ptr)

	return wrap_envelope('    <ech:RankProversResponse>
      <ech:Success>true</ech:Success>
      <ech:Data>${result_str}</ech:Data>
    </ech:RankProversResponse>')
}

fn handle_authenticate(body string) string {
	token := extract_xml_value(body, 'Token')
	max_calls := extract_xml_int(body, 'MaxCalls', 100)
	expiry_ms := extract_xml_int(body, 'ExpiryMs', 60000)

	if token.len == 0 {
		return soap_fault('Client', 'missing required element: Token')
	}

	result := C.echidna_llm_authenticate(token.str, token.len, max_calls, expiry_ms)
	if result != 0 {
		msg := match result {
			-1 { 'invalid state transition — session already active' }
			-2 { 'max_calls must be between 1 and 1000' }
			-3 { 'expiry_ms must be positive' }
			else { 'authentication failed with code ${result}' }
		}
		return soap_fault('Client', msg)
	}

	C.echidna_llm_start_operating()
	state := C.echidna_llm_get_state()

	return wrap_envelope('    <ech:AuthenticateResponse>
      <ech:Success>true</ech:Success>
      <ech:State>${state_label(state)}</ech:State>
      <ech:MaxCalls>${max_calls}</ech:MaxCalls>
      <ech:ExpiryMs>${expiry_ms}</ech:ExpiryMs>
    </ech:AuthenticateResponse>')
}

fn handle_status() string {
	state := C.echidna_llm_get_state()
	valid := C.echidna_llm_session_valid() == 1

	return wrap_envelope('    <ech:GetStatusResponse>
      <ech:State>${state_label(state)}</ech:State>
      <ech:SessionValid>${valid}</ech:SessionValid>
    </ech:GetStatusResponse>')
}

fn handle_close() string {
	result := C.echidna_llm_close()
	state := C.echidna_llm_get_state()

	if result != 0 {
		return soap_fault('Client', 'cannot close — no active session')
	}

	return wrap_envelope('    <ech:CloseSessionResponse>
      <ech:Success>true</ech:Success>
      <ech:State>${state_label(state)}</ech:State>
    </ech:CloseSessionResponse>')
}

fn handle_health() string {
	return wrap_envelope('    <ech:HealthResponse>
      <ech:Status>ok</ech:Status>
      <ech:Adapter>echidna_llm_soap</ech:Adapter>
    </ech:HealthResponse>')
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

fn test_soap_health() {
	response := dispatch(action_health, '')
	assert response.contains('soap:Envelope')
	assert response.contains('echidna_llm_soap')
	assert response.contains('<ech:Status>ok</ech:Status>')
}

fn test_soap_status() {
	response := dispatch(action_status, '')
	assert response.contains('soap:Envelope')
	assert response.contains('GetStatusResponse')
	assert response.contains('State')
}

fn test_soap_suggest_no_session() {
	body := '<ech:SuggestTacticsRequest><ech:Goal>forall n, n + 0 = n</ech:Goal></ech:SuggestTacticsRequest>'
	response := dispatch(action_suggest, body)
	assert response.contains('soap:Fault')
	assert response.contains('session')
}

fn test_soap_suggest_missing_goal() {
	body := '<ech:SuggestTacticsRequest></ech:SuggestTacticsRequest>'
	response := dispatch(action_suggest, body)
	assert response.contains('soap:Fault')
	assert response.contains('missing required element')
}

fn test_soap_unknown_action() {
	response := dispatch('urn:echidna-llm:Explode', '')
	assert response.contains('soap:Fault')
	assert response.contains('unknown SOAPAction')
}

fn test_soap_extract_xml_value() {
	xml := '<ech:Goal>forall n, n + 0 = n</ech:Goal>'
	assert extract_xml_value(xml, 'Goal') == 'forall n, n + 0 = n'
}

fn test_soap_extract_xml_int() {
	xml := '<ech:TopK>25</ech:TopK>'
	assert extract_xml_int(xml, 'TopK', 10) == 25
}

fn test_soap_extract_missing() {
	xml := '<ech:Other>value</ech:Other>'
	assert extract_xml_value(xml, 'Goal') == ''
	assert extract_xml_int(xml, 'TopK', 10) == 10
}

fn test_soap_envelope_structure() {
	response := dispatch(action_health, '')
	assert response.starts_with('<?xml version="1.0"')
	assert response.contains('xmlns:soap="${soap_env_ns}"')
	assert response.contains('xmlns:ech="${soap_ns}"')
}
