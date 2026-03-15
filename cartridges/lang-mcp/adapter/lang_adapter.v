// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Lang-MCP Cartridge — V-lang adapter layer.
//
// Bridges the Zig FFI (lang_ffi.zig) to REST/gRPC/GraphQL endpoints.
// Provides language session management, type-checking, and evaluation
// for the hyperpolymath nextgen-languages family.

module lang_adapter

import json

// ═══════════════════════════════════════════════════════════════════════
// C FFI declarations (link against lang_ffi built from Zig)
// ═══════════════════════════════════════════════════════════════════════

fn C.lang_session_start(lang_id int, name_ptr &u8, name_len usize) int
fn C.lang_session_start_dialect(lang_id int, dialect_mode int, name_ptr &u8, name_len usize) int
fn C.lang_session_dialect(sess_idx int) int
fn C.lang_session_set_url(sess_idx int, url_ptr &u8, url_len usize) int
fn C.lang_session_end(sess_idx int) int
fn C.lang_session_state(sess_idx int) int
fn C.lang_session_language(sess_idx int) int
fn C.lang_typecheck(sess_idx int, src_ptr &u8, src_len usize, out_ptr &u8, out_len usize) int
fn C.lang_eval(sess_idx int, src_ptr &u8, src_len usize, out_ptr &u8, out_len usize) int
fn C.lang_reset()

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

enum LangState {
	idle = 0
	compiling = 1
	checked = 2
	evaluating = 3
	err = 4
}

enum Language {
	eclexia = 1
	affinescript = 2
	betlang = 3
	ephapax = 4
	mylang = 5
	wokelang = 6
	anvomidav = 7
	phronesis = 8
	error_lang = 9
	julia_the_viper = 10
	me_dialect = 11
	oblibeny = 12
	custom = 99
}

fn state_label(s int) string {
	return match s {
		0 { 'idle' }
		1 { 'compiling' }
		2 { 'checked' }
		3 { 'evaluating' }
		4 { 'error' }
		else { 'unknown' }
	}
}

fn language_label(lang string) !int {
	return match lang {
		'eclexia' { 1 }
		'affinescript' { 2 }
		'betlang' { 3 }
		'ephapax' { 4 }
		'mylang' { 5 }
		'wokelang' { 6 }
		'anvomidav' { 7 }
		'phronesis' { 8 }
		'error-lang' { 9 }
		'julia-the-viper' { 10 }
		'me-dialect' { 11 }
		'oblibeny' { 12 }
		else { return error('unknown language: ${lang}') }
	}
}

// ═══════════════════════════════════════════════════════════════════════
// REST API Responses
// ═══════════════════════════════════════════════════════════════════════

struct SessionResponse {
	session  int
	language string
	state    string
}

// ═══════════════════════════════════════════════════════════════════════
// Adapter Functions (called by main adapter router)
// ═══════════════════════════════════════════════════════════════════════

// Start a language session. dialect: "pure" (default) or "jtv" (JtV-injected).
// JtV (Julia-the-Viper) is injectable into any other language, augmenting its
// grammar with JtV syntax extensions. Request "eclexia+jtv" or pass dialect="jtv".
pub fn start_session(language_name string, session_name string) !SessionResponse {
	return start_session_dialect(language_name, 'pure', session_name)
}

pub fn start_session_dialect(language_name string, dialect string, session_name string) !SessionResponse {
	// Parse "eclexia+jtv" shorthand
	mut lang := language_name
	mut dial := dialect
	if language_name.contains('+jtv') {
		lang = language_name.replace('+jtv', '')
		dial = 'jtv'
	}
	lang_id := language_label(lang)!
	dialect_mode := if dial == 'jtv' { 1 } else { 0 }
	sess := C.lang_session_start_dialect(lang_id, dialect_mode, session_name.str, usize(session_name.len))
	if sess < 0 {
		return match sess {
			-1 { error('no session slots available (max 8)') }
			-2 { error('invalid session name') }
			else { error('unknown error (code ${sess})') }
		}
	}
	return SessionResponse{
		session: sess
		language: if dial == 'jtv' { '${lang}+jtv' } else { lang }
		state: 'idle'
	}
}

pub fn set_url(session int, url string) !string {
	result := C.lang_session_set_url(session, url.str, usize(url.len))
	return match result {
		0 { 'URL set for session ${session}' }
		-1 { return error('invalid or inactive session') }
		-6 { return error('URL empty or too long') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn end_session(session int) !string {
	result := C.lang_session_end(session)
	return match result {
		0 { 'session ${session} ended' }
		-1 { return error('invalid or inactive session') }
		else { return error('unknown error (code ${result})') }
	}
}

pub fn get_state(session int) string {
	s := C.lang_session_state(session)
	return state_label(s)
}

pub fn typecheck(session int, source string) !string {
	if session < 0 || session > 7 {
		return error('invalid session index: ${session}')
	}
	mut out_buf := []u8{len: 65536}
	result := C.lang_typecheck(session, source.str, usize(source.len), out_buf.data, usize(out_buf.len))
	if result < 0 {
		return match result {
			-1 { error('invalid or inactive session') }
			-2 { error('session not in valid state for type-checking') }
			-5 { error('output buffer too small') }
			-6 { error('no service URL set for this session') }
			-7 { error('type-check service call failed') }
			else { error('unknown error (code ${result})') }
		}
	}
	return out_buf[..result].bytestr()
}

pub fn evaluate(session int, source string) !string {
	if session < 0 || session > 7 {
		return error('invalid session index: ${session}')
	}
	mut out_buf := []u8{len: 65536}
	result := C.lang_eval(session, source.str, usize(source.len), out_buf.data, usize(out_buf.len))
	if result < 0 {
		return match result {
			-1 { error('invalid or inactive session') }
			-2 { error('session not in valid state for evaluation') }
			-5 { error('output buffer too small') }
			-6 { error('no service URL set for this session') }
			-7 { error('evaluation service call failed') }
			else { error('unknown error (code ${result})') }
		}
	}
	return out_buf[..result].bytestr()
}

pub fn list_languages() string {
	return '{"languages":["eclexia","affinescript","betlang","ephapax","mylang","wokelang","anvomidav","phronesis","error-lang","julia-the-viper","me-dialect","oblibeny"],"dialects":["pure","jtv"],"note":"JtV (Julia-the-Viper) is injectable into any language. Request \'eclexia+jtv\' or pass dialect=jtv to get JtV-augmented grammar alongside the base language."}'
}

pub fn reset() {
	C.lang_reset()
}
