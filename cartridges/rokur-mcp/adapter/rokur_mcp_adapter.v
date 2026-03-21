// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// rokur_mcp_adapter.v — V-lang REST adapter for the rokur-mcp cartridge.
//
// Container pre-start secrets gate. Bridges the Zig FFI C-ABI exports to
// the unified BoJ adapter protocol. Secret values are never exposed —
// only presence/absence verdicts and counts.

module rokur_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lrokur_mcp

fn C.rokur_mcp_can_transition(from int, to int) int
fn C.rokur_mcp_state() int
fn C.rokur_mcp_transition(to int) int
fn C.rokur_mcp_action_permitted(action int) int
fn C.rokur_mcp_authorize(token_ptr &u8, token_len int, image_ptr &u8, image_len int) int
fn C.rokur_mcp_health(token_ptr &u8, token_len int) int
fn C.rokur_mcp_secrets_status(token_ptr &u8, token_len int) int
fn C.rokur_mcp_reload(token_ptr &u8, token_len int) int
fn C.rokur_mcp_read_result(out_ptr &u8, max_len int) int
fn C.rokur_mcp_read_error(out_ptr &u8, max_len int) int
fn C.rokur_mcp_last_verdict() int
fn C.rokur_mcp_check_count() int
fn C.rokur_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum GateState {
	idle     = 0
	checking = 1
	allowed  = 2
	denied   = 3
	err      = 4
}

fn state_label(s int) string {
	return match s {
		0 { 'idle' }
		1 { 'checking' }
		2 { 'allowed' }
		3 { 'denied' }
		4 { 'error' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct StateResponse {
	state string
}

struct AuthResponse {
	allowed     bool
	raw_result  string
}

struct GateStatusResponse {
	state        string
	check_count  int
	last_verdict string
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

const result_buf_size = 4096

fn read_result() string {
	mut buf := []u8{len: result_buf_size}
	n := C.rokur_mcp_read_result(buf.data, result_buf_size)
	if n <= 0 {
		return ''
	}
	return buf[..n].bytestr()
}

fn read_error() string {
	mut buf := []u8{len: 512}
	n := C.rokur_mcp_read_error(buf.data, 512)
	if n <= 0 {
		return 'unknown error'
	}
	return buf[..n].bytestr()
}

// ---------------------------------------------------------------------------
// Adapter functions — REST API bridge
// ---------------------------------------------------------------------------

/// GET /rokur/state — query current gate state.
pub fn rokur_state() StateResponse {
	s := C.rokur_mcp_state()
	return StateResponse{
		state: state_label(s)
	}
}

/// POST /rokur/authorize-start — request pre-start container authorization.
/// Calls the Rokur sidecar to validate required secrets presence.
/// Returns allow/deny verdict without exposing secret values.
pub fn rokur_authorize(token string, image string) !AuthResponse {
	result := C.rokur_mcp_authorize(
		token.str, token.len,
		image.str, image.len,
	)
	if result < 0 {
		return match result {
			-1 { error('gate not in idle state') }
			-2 { error('rokur sidecar unreachable: ${read_error()}') }
			-3 { error('invalid parameters') }
			else { error('unknown error (code ${result})') }
		}
	}
	return AuthResponse{
		allowed: C.rokur_mcp_last_verdict() == 1
		raw_result: read_result()
	}
}

/// GET /rokur/health — Rokur sidecar liveness check.
pub fn rokur_health(token string) !string {
	result := C.rokur_mcp_health(token.str, token.len)
	if result < 0 {
		return error('health check failed: ${read_error()}')
	}
	return read_result()
}

/// GET /rokur/secrets/status — query secrets presence status.
pub fn rokur_secrets_status(token string) !string {
	result := C.rokur_mcp_secrets_status(token.str, token.len)
	if result < 0 {
		return error('secrets status failed: ${read_error()}')
	}
	return read_result()
}

/// POST /rokur/reload — hot-reload required secrets from environment.
pub fn rokur_reload(token string) !string {
	result := C.rokur_mcp_reload(token.str, token.len)
	if result < 0 {
		return error('reload failed: ${read_error()}')
	}
	return read_result()
}

/// GET /rokur/status — gate operational status.
pub fn rokur_status() GateStatusResponse {
	return GateStatusResponse{
		state: state_label(C.rokur_mcp_state())
		check_count: C.rokur_mcp_check_count()
		last_verdict: if C.rokur_mcp_last_verdict() == 1 { 'allowed' } else { 'denied' }
	}
}

/// Reset gate to initial state (test/debug only).
pub fn reset() {
	C.rokur_mcp_reset()
}
