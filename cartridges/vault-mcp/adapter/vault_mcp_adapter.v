// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vault_mcp_adapter.v — V-lang REST adapter for the vault-mcp cartridge.
//
// Zero-knowledge credential proxy: bridges the Zig FFI C-ABI exports to the
// unified BoJ adapter protocol. BoJ cartridges never see credentials directly.
// The vault (reasonably-good-token-vault) resolves credential hints internally.

module vault_mcp_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -lvault_mcp

fn C.vault_mcp_can_transition(from int, to int) int
fn C.vault_mcp_state() int
fn C.vault_mcp_transition(to int) int
fn C.vault_mcp_action_permitted(action int) int
fn C.vault_mcp_execute(command_ptr &u8, command_len int, hint_ptr &u8, hint_len int) int
fn C.vault_mcp_list() int
fn C.vault_mcp_status() int
fn C.vault_mcp_verify(hint_ptr &u8, hint_len int) int
fn C.vault_mcp_rotate(hint_ptr &u8, hint_len int) int
fn C.vault_mcp_read_result(out_ptr &u8, max_len int) int
fn C.vault_mcp_read_error(out_ptr &u8, max_len int) int
fn C.vault_mcp_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

/// Vault lifecycle states for the zero-knowledge credential proxy.
enum VaultState {
	locked      = 0
	mfa_pending = 1
	unlocked    = 2
	sealed      = 3
}

/// Vault actions matching the MCP tool surface.
enum VaultAction {
	execute = 0
	list    = 1
	rotate  = 2
	status  = 3
	verify  = 4
}

/// Human-readable label for a vault state integer.
fn state_label(s int) string {
	return match s {
		0 { 'locked' }
		1 { 'mfa_pending' }
		2 { 'unlocked' }
		3 { 'sealed' }
		else { 'unknown' }
	}
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Response from vault state queries.
struct StateResponse {
	state string
}

/// Response from vault/execute, vault/list, vault/verify, vault/rotate.
struct VaultResponse {
	action string
	result string
}

/// Response from vault/status including metadata.
struct StatusResponse {
	state            string
	credential_count int
	last_access      i64
}

/// Response from transition validity checks.
struct TransitionResponse {
	from  int
	to    int
	valid bool
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

const result_buf_size = 8192

/// Read the result buffer from the last FFI operation.
fn read_result() string {
	mut buf := []u8{len: result_buf_size}
	n := C.vault_mcp_read_result(buf.data, result_buf_size)
	if n <= 0 {
		return ''
	}
	return buf[..n].bytestr()
}

/// Read the error buffer from the last FFI operation.
fn read_error() string {
	mut buf := []u8{len: 512}
	n := C.vault_mcp_read_error(buf.data, 512)
	if n <= 0 {
		return 'unknown error'
	}
	return buf[..n].bytestr()
}

// ---------------------------------------------------------------------------
// Adapter functions — REST API bridge
// ---------------------------------------------------------------------------

/// GET /vault/state — query current vault state.
pub fn vault_state() StateResponse {
	s := C.vault_mcp_state()
	return StateResponse{
		state: state_label(s)
	}
}

/// POST /vault/transition — transition vault to a new state.
pub fn vault_transition(to int) !StateResponse {
	result := C.vault_mcp_transition(to)
	return match result {
		0 { StateResponse{ state: state_label(to) } }
		-1 { return error('invalid state value: ${to}') }
		-2 { return error('invalid state transition to ${state_label(to)}') }
		else { return error('unknown error (code ${result})') }
	}
}

/// POST /vault/execute — execute command with vault-managed credentials.
/// This is the primary MCP tool: vault/execute.
/// The credential_hint identifies which service needs auth (e.g. "github.com").
/// The command is executed by svalinn_cli which injects the credential.
/// The adapter NEVER sees the actual secret.
pub fn vault_execute(command string, credential_hint string) !VaultResponse {
	result := C.vault_mcp_execute(
		command.str, command.len,
		credential_hint.str, credential_hint.len,
	)
	if result < 0 {
		return match result {
			-1 { error('vault is not unlocked') }
			-2 { error('credential execution failed: ${read_error()}') }
			-3 { error('invalid parameters') }
			else { error('unknown error (code ${result})') }
		}
	}
	return VaultResponse{
		action: 'execute'
		result: read_result()
	}
}

/// GET /vault/list — list available credential hints.
/// Returns the list of services/hints the vault knows about,
/// without ever exposing the actual credentials.
pub fn vault_list() !VaultResponse {
	result := C.vault_mcp_list()
	if result < 0 {
		return match result {
			-1 { error('vault is not unlocked') }
			-2 { error('list operation failed: ${read_error()}') }
			else { error('unknown error (code ${result})') }
		}
	}
	return VaultResponse{
		action: 'list'
		result: read_result()
	}
}

/// GET /vault/status — query vault operational status.
/// Available in any vault state (locked, unlocked, sealed).
pub fn vault_status() !VaultResponse {
	result := C.vault_mcp_status()
	if result < 0 {
		return match result {
			-2 { error('status query failed: ${read_error()}') }
			else { error('unknown error (code ${result})') }
		}
	}
	return VaultResponse{
		action: 'status'
		result: read_result()
	}
}

/// POST /vault/verify — verify credential integrity for a hint.
pub fn vault_verify(credential_hint string) !VaultResponse {
	result := C.vault_mcp_verify(
		credential_hint.str, credential_hint.len,
	)
	if result < 0 {
		return match result {
			-1 { error('vault is not unlocked') }
			-2 { error('verify failed: ${read_error()}') }
			-3 { error('invalid parameters') }
			else { error('unknown error (code ${result})') }
		}
	}
	return VaultResponse{
		action: 'verify'
		result: read_result()
	}
}

/// POST /vault/rotate — rotate credential for a hint.
pub fn vault_rotate(credential_hint string) !VaultResponse {
	result := C.vault_mcp_rotate(
		credential_hint.str, credential_hint.len,
	)
	if result < 0 {
		return match result {
			-1 { error('vault is not unlocked') }
			-2 { error('rotation failed: ${read_error()}') }
			-3 { error('invalid parameters') }
			else { error('unknown error (code ${result})') }
		}
	}
	return VaultResponse{
		action: 'rotate'
		result: read_result()
	}
}

/// Check if a transition is valid (utility, not a REST endpoint).
pub fn can_transition(from int, to int) TransitionResponse {
	valid := C.vault_mcp_can_transition(from, to) == 1
	return TransitionResponse{ from: from, to: to, valid: valid }
}

/// Reset vault to initial locked state (test/debug only).
pub fn reset() {
	C.vault_mcp_reset()
}
