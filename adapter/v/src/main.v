// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — V-lang Triple Adapter
//
// This is the unified console that exposes mounted cartridges as:
//   - REST (port 9000)
//   - gRPC (port 9001)
//   - GraphQL (port 9002)
//
// The adapter reads the order-ticket.scm, mounts cartridges via the
// Zig FFI, and creates protocol-specific endpoints for each mounted
// cartridge.
//
// Phase 3 implementation — stub for now.

module main

// BojOrder represents a parsed order-ticket.scm request.
struct BojOrder {
	timestamp       i64
	requested_by    string
	session_id      string
	cartridge_names []string
	preferred_node  string  // empty for local
	fallback        string  // "local" | "any" | "none"
}

// CartridgeEndpoint describes a mounted cartridge's network address.
struct CartridgeEndpoint {
	cartridge_name string
	protocol       string
	address        string
}

// BojStatus is returned by the /status endpoint.
struct BojStatus {
	version           string
	total_cartridges  int
	ready_cartridges  int
	mounted_cartridges int
	endpoints         []CartridgeEndpoint
	node_id           string
	region            string
	uptime_seconds    i64
}

fn main() {
	println('BoJ Server v0.1.0 — The Teranga Console')
	println('Phase 3: V-lang triple adapter (REST+gRPC+GraphQL)')
	println('Ports: REST=9000, gRPC=9001, GraphQL=9002')
	println('')
	println('Status: stub — awaiting Phase 2 (Zig FFI) completion')

	// TODO Phase 3:
	// 1. Read order-ticket.scm from .machine_readable/servers/
	// 2. Call boj_catalogue_init() via C FFI
	// 3. Register cartridges from menu.a2ml
	// 4. Mount requested cartridges (validates IsUnbreakable)
	// 5. Create REST router on port 9000
	// 6. Create gRPC listener on port 9001
	// 7. Create GraphQL endpoint on port 9002
	// 8. Expose /status, /menu, /order endpoints
	// 9. Serve until signal
}
