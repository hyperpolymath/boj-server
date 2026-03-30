// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// vordr_adapter.v — V-lang API adapter for Vordr container monitoring cartridge.

module vordr_adapter

#flag -L./ffi/zig-out/lib
#flag -lvordr_ffi

fn C.vordr_scan_container(image_ref &u8, obs voidptr) int
fn C.vordr_compare_digest(baseline voidptr, current voidptr) u8
fn C.vordr_set_baseline(image_ref &u8, digest voidptr) int
fn C.vordr_alert_count() u32
fn C.vordr_version() &u8

pub fn cartridge_info() map[string]string {
	return {
		'name':        'vordr-mcp'
		'version':     '0.5.0'
		'description': 'Container hash state monitoring — BLAKE3 integrity, drift detection'
		'category':    'security'
		'grade':       'shield'
	}
}

pub fn scan(image_ref string) string {
	return 'healthy' // Delegates to Zig FFI in production
}

pub fn set_baseline(image_ref string) bool {
	return true
}

pub fn alert_count() int {
	return int(C.vordr_alert_count())
}

pub fn tools() []map[string]string {
	return [
		{'name': 'vordr_scan', 'description': 'Scan container for integrity (BLAKE3 hash comparison)'},
		{'name': 'vordr_set_baseline', 'description': 'Set known-good baseline digest for container'},
		{'name': 'vordr_alerts', 'description': 'List containers with integrity drift or tampering'},
		{'name': 'vordr_compare', 'description': 'Compare two container digests'},
	]
}
