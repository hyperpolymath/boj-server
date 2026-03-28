// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
//
// PanicAttack V-lang adapter — bridges Zig FFI to REST endpoints.

module panic_attack_adapter

fn C.panic_attack_scan(target &u8) u32
fn C.panic_attack_get_findings_count(scan_id u32) u32
fn C.panic_attack_get_severity(scan_id u32) u8

struct ScanRequest {
	target string
}

struct Response {
	ok   bool
	data string
}

pub fn handle_scan(req ScanRequest) Response {
	scan_id := C.panic_attack_scan(req.target.str)
	if scan_id == 0 {
		return Response{ ok: false, data: 'invalid target' }
	}
	return Response{ ok: true, data: '${scan_id}' }
}

pub fn handle_get_findings(scan_id u32) Response {
	count := C.panic_attack_get_findings_count(scan_id)
	return Response{ ok: true, data: '${count}' }
}

pub fn handle_get_severity(scan_id u32) Response {
	sev := C.panic_attack_get_severity(scan_id)
	labels := ['info', 'low', 'medium', 'high', 'critical']
	label := if sev < labels.len { labels[sev] } else { 'unknown' }
	return Response{ ok: true, data: label }
}
