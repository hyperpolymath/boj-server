// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Vext V-lang adapter — bridges Zig FFI to REST endpoints.

module vext_adapter

fn C.vext_verify_message(msg &u8, sig &u8) u8
fn C.vext_check_attestation(issuer &u8) u32
fn C.vext_append_chain(payload &u8) int

struct Response {
	ok   bool
	data string
}

pub fn handle_verify_message(msg string, sig string) Response {
	status := C.vext_verify_message(msg.str, sig.str)
	labels := ['verified', 'unverified', 'tampered', 'expired']
	label := if status < labels.len { labels[status] } else { 'unknown' }
	return Response{ ok: status == 0, data: label }
}

pub fn handle_check_attestation(issuer string) Response {
	depth := C.vext_check_attestation(issuer.str)
	if depth == 0 {
		return Response{ ok: false, data: 'not found' }
	}
	return Response{ ok: true, data: 'depth ${depth}' }
}

pub fn handle_append_chain(payload string) Response {
	rc := C.vext_append_chain(payload.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'appended' } else { 'error' } }
}
