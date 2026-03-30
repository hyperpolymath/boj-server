// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// pmpl_adapter.v — V-lang API adapter for PMPL provenance chain cartridge.

module pmpl_adapter

#flag -L./ffi/zig-out/lib
#flag -lpmpl_ffi

fn C.pmpl_create_chain(entry voidptr) int
fn C.pmpl_extend_chain(parent_hash &u8, entry voidptr) int
fn C.pmpl_verify_chain(root_hash &u8) int
fn C.pmpl_hash_artifact(path &u8, out_hash &u8, out_len &u32) int
fn C.pmpl_compatible(license u8) bool
fn C.pmpl_version() &u8

pub fn cartridge_info() map[string]string {
	return {
		'name':        'pmpl-mcp'
		'version':     '0.5.0'
		'description': 'PMPL provenance chain — BLAKE3 hashing, license compatibility, append-only chain'
		'category':    'security'
		'grade':       'shield'
	}
}

pub fn verify_chain(root_hash string) bool {
	return C.pmpl_verify_chain(root_hash.str) == 0
}

pub fn check_compatible(license string) bool {
	license_id := match license {
		'PMPL-1.0-or-later' { u8(0) }
		'MPL-2.0' { u8(1) }
		'MIT' { u8(2) }
		'Apache-2.0' { u8(3) }
		'BSD-2-Clause' { u8(4) }
		'BSD-3-Clause' { u8(5) }
		else { return false }
	}
	return C.pmpl_compatible(license_id)
}

pub fn tools() []map[string]string {
	return [
		{'name': 'pmpl_verify', 'description': 'Verify PMPL provenance chain integrity (BLAKE3)'},
		{'name': 'pmpl_extend', 'description': 'Add entry to provenance chain (append-only)'},
		{'name': 'pmpl_hash', 'description': 'Hash artifact content with BLAKE3'},
		{'name': 'pmpl_compatible', 'description': 'Check if license is PMPL-compatible'},
		{'name': 'pmpl_lookup', 'description': 'Look up provenance chain by content hash'},
	]
}
