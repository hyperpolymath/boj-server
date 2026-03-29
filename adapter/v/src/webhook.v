// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Webhook Security Module
//
// Implements HMAC-SHA256 verification for GitHub and other forge webhooks.
// Ensures that incoming build triggers are authentic and untampered.

module main

import crypto.hmac
import crypto.sha256
import os

// verify_github_signature validates the X-Hub-Signature-256 header.
// Secret is sourced from BOJ_GITHUB_WEBHOOK_SECRET env var.
fn verify_github_signature(payload string, signature_header string) bool {
	secret := os.getenv('BOJ_GITHUB_WEBHOOK_SECRET')
	if secret == '' {
		// If no secret is configured, we fail closed for security.
		return false
	}

	if !signature_header.starts_with('sha256=') {
		return false
	}

	// Extract the hex signature (strip 'sha256=')
	expected_sig := signature_header[7..]
	
	// Calculate HMAC-SHA256 of the payload
	actual_sig := hmac.new(secret.bytes(), payload.bytes(), sha256.sum, sha256.block_size).hex()

	// Constant-time comparison to prevent timing attacks
	return safe_compare(actual_sig, expected_sig)
}

// safe_compare performs a constant-time comparison of two strings.
// This is a security-critical function to prevent timing attacks.
fn safe_compare(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	mut result := 0
	for i in 0 .. a.len {
		result |= a[i] ^ b[i]
	}
	return result == 0
}
