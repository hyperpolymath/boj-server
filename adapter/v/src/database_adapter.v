// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// BoJ Server — Database Adapter Stub
//
// Placeholder for Zig FFI-based database connections (SQLite, VeriSimDB).
// Currently returns errors directing callers to use shell-based tools.
// Will be replaced with proper Zig FFI calls when database-mcp FFI matures.

module main

// DatabaseConnection represents an active database connection slot.
struct DatabaseConnection {
	slot int
}

// DatabaseAdapter manages database connections via Zig FFI.
// Currently a stub that returns errors — the Zig FFI state machine
// for database-mcp is not yet wired to the V adapter.
struct DatabaseAdapter {}

// connect_sqlite opens a connection to a SQLite database file.
fn (d DatabaseAdapter) connect_sqlite(path string) !DatabaseConnection {
	return error('database_adapter: SQLite FFI not yet wired — use sqlite3 CLI via observe-mcp')
}

// execute_sql runs a SQL query on an open connection.
fn (d DatabaseAdapter) execute_sql(slot int, query string) !string {
	return error('database_adapter: SQL FFI not yet wired')
}

// connect_verisimdb opens a connection to a VeriSimDB instance.
fn (d DatabaseAdapter) connect_verisimdb(url string) !DatabaseConnection {
	return error('database_adapter: VeriSimDB FFI not yet wired — use curl via observe-mcp')
}

// execute_vql runs a VQL query on an open VeriSimDB connection.
fn (d DatabaseAdapter) execute_vql(slot int, vql_body string) !string {
	return error('database_adapter: VQL FFI not yet wired')
}

// disconnect closes a database connection.
fn (d DatabaseAdapter) disconnect(slot int) {
	// No-op until FFI is wired
}

// Module-level singleton — referenced as `database_adapter` in main.v
const database_adapter = DatabaseAdapter{}
