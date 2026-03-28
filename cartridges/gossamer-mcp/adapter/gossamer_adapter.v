// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// Gossamer V-lang adapter — bridges Zig FFI to REST endpoints.

module gossamer_adapter

import json
import net.http

// FFI declarations linking to gossamer_ffi.zig exports.
fn C.gossamer_create_window(width u32, height u32) u32
fn C.gossamer_load_panel(handle u32, uri &u8) int
fn C.gossamer_eval_js(handle u32, script &u8) int
fn C.gossamer_get_version() u32

// CreateWindow request payload.
struct CreateWindowReq {
	width  u32
	height u32
}

// Unified JSON response.
struct Response {
	ok   bool
	data string
}

// Create a webview window via FFI.
pub fn handle_create_window(req CreateWindowReq) Response {
	handle := C.gossamer_create_window(req.width, req.height)
	if handle == 0 {
		return Response{ ok: false, data: 'invalid dimensions' }
	}
	return Response{ ok: true, data: '${handle}' }
}

// Load a panel into an existing window.
pub fn handle_load_panel(handle u32, uri string) Response {
	rc := C.gossamer_load_panel(handle, uri.str)
	return Response{ ok: rc == 0, data: if rc == 0 { 'loaded' } else { 'error' } }
}

// Get Gossamer runtime version.
pub fn handle_get_version() Response {
	v := C.gossamer_get_version()
	major := (v >> 16) & 0xFF
	minor := (v >> 8) & 0xFF
	patch := v & 0xFF
	return Response{ ok: true, data: '${major}.${minor}.${patch}' }
}
