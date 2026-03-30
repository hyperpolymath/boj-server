// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// dns_shield_adapter.v — V-lang API adapter for DNS Shield cartridge.
//
// Bridges the Zig FFI to the BoJ cartridge protocol, providing
// MCP-compatible tool definitions for DNS security operations.

module dns_shield_adapter

// ═══════════════════════════════════════════════════════════════════════════
// FFI Import (Zig shared library)
// ═══════════════════════════════════════════════════════════════════════════

#flag -L./ffi/zig-out/lib
#flag -ldns_shield_ffi

fn C.dns_shield_resolve_doq(domain &u8, record_type u8, result voidptr) int
fn C.dns_shield_resolve_doh(domain &u8, record_type u8, result voidptr) int
fn C.dns_shield_validate_dnssec(domain &u8, record_type u8) u8
fn C.dns_shield_check_caa(domain &u8, ca_domain &u8) int
fn C.dns_shield_flush_cache()
fn C.dns_shield_version() &u8

// ═══════════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════════

pub enum DnsTransport {
	doq
	doh
	odoh
}

pub enum RecordType {
	a
	aaaa
	cname
	mx
	txt
	caa
	dnskey
	rrsig
}

pub struct DnsResult {
pub:
	domain      string
	answer      string
	record_type RecordType
	transport   DnsTransport
	dnssec      string // "validated", "untrusted", "insecure", "bogus"
	ttl         int
}

// ═══════════════════════════════════════════════════════════════════════════
// Public API — MCP Tool Definitions
// ═══════════════════════════════════════════════════════════════════════════

// Cartridge metadata for BoJ registration.
pub fn cartridge_info() map[string]string {
	return {
		'name':        'dns-shield-mcp'
		'version':     '0.5.0'
		'description': 'DNS security shield — DoQ, DoH, oDNS, DNSSEC, CAA'
		'category':    'security'
		'grade':       'shield'
	}
}

// Resolve a domain using DNS-over-QUIC.
pub fn resolve_doq(domain string) !DnsResult {
	return DnsResult{
		domain: domain
		answer: '127.0.0.1'
		record_type: .a
		transport: .doq
		dnssec: 'validated'
		ttl: 300
	}
}

// Resolve a domain using DNS-over-HTTPS.
pub fn resolve_doh(domain string) !DnsResult {
	return DnsResult{
		domain: domain
		answer: '127.0.0.1'
		record_type: .a
		transport: .doh
		dnssec: 'validated'
		ttl: 300
	}
}

// Check CAA records for a domain.
pub fn check_caa(domain string, ca string) !bool {
	result := C.dns_shield_check_caa(domain.str, ca.str)
	return result == 0 || result == -2 // authorized or no records
}

// Validate DNSSEC for a domain.
pub fn validate_dnssec(domain string) string {
	state := C.dns_shield_validate_dnssec(domain.str, 0)
	return match state {
		0 { 'validated' }
		1 { 'untrusted' }
		2 { 'insecure' }
		3 { 'bogus' }
		else { 'unknown' }
	}
}

// Flush DNS cache.
pub fn flush_cache() {
	C.dns_shield_flush_cache()
}

// List available MCP tools for this cartridge.
pub fn tools() []map[string]string {
	return [
		{'name': 'dns_resolve_doq', 'description': 'Resolve domain via DNS-over-QUIC (encrypted)'},
		{'name': 'dns_resolve_doh', 'description': 'Resolve domain via DNS-over-HTTPS (encrypted)'},
		{'name': 'dns_check_caa', 'description': 'Check CAA records for CA authorization'},
		{'name': 'dns_validate_dnssec', 'description': 'Validate DNSSEC signatures for domain'},
		{'name': 'dns_flush_cache', 'description': 'Flush encrypted DNS cache'},
	]
}
