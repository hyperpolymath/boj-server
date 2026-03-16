// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Template generators for cartridge scaffolding.
// Each function returns the complete file content for one layer of the 3-layer stack.

use crate::config::CartridgeConfig;

/// Generate the Idris2 ABI module (SafeXxx.idr).
///
/// Creates a state-machine skeleton with ValidTransition proofs,
/// C-ABI integer exports, and MCP tool declarations.
pub fn idris2_abi(cfg: &CartridgeConfig) -> String {
    let pkg = cfg.idris_package_name();
    let domain_mod = cfg.domain.idris_module_name();
    let ffi_name = cfg.ffi_name();

    format!(
        r#"-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- {pkg}.Safe{domain_mod} — Type-safe ABI for {name} cartridge.
--
-- State machine with dependent-type proofs ensuring only valid transitions
-- can occur at the FFI boundary. Zero unsafe escape hatches.

module {pkg}.Safe{domain_mod}

%default total

-- ---------------------------------------------------------------------------
-- State machine
-- ---------------------------------------------------------------------------

||| Connection/session state for {name} operations.
public export
data SessionState = Idle | Active | Processing | Error

||| Proof that a state transition is valid.
public export
data ValidTransition : SessionState -> SessionState -> Type where
  Activate   : ValidTransition Idle Active
  BeginWork  : ValidTransition Active Processing
  EndWork    : ValidTransition Processing Active
  Deactivate : ValidTransition Active Idle
  WorkError  : ValidTransition Processing Error
  Recover    : ValidTransition Error Idle

-- ---------------------------------------------------------------------------
-- C-ABI integer encoding
-- ---------------------------------------------------------------------------

||| Encode session state as C-compatible integer.
export
sessionStateToInt : SessionState -> Int
sessionStateToInt Idle       = 0
sessionStateToInt Active     = 1
sessionStateToInt Processing = 2
sessionStateToInt Error      = 3

||| Decode integer back to session state.
export
intToSessionState : Int -> Maybe SessionState
intToSessionState 0 = Just Idle
intToSessionState 1 = Just Active
intToSessionState 2 = Just Processing
intToSessionState 3 = Just Error
intToSessionState _ = Nothing

||| Check if a state transition is valid (C-ABI export).
||| Returns 1 for valid, 0 for invalid.
export
{ffi_name}_can_transition : Int -> Int -> Int
{ffi_name}_can_transition from to =
  case (intToSessionState from, intToSessionState to) of
    (Just Idle,       Just Active)     => 1
    (Just Active,     Just Processing) => 1
    (Just Processing, Just Active)     => 1
    (Just Active,     Just Idle)       => 1
    (Just Processing, Just Error)      => 1
    (Just Error,      Just Idle)       => 1
    _                                  => 0

-- ---------------------------------------------------------------------------
-- Backend types
-- ---------------------------------------------------------------------------

||| Backend implementations supported by this cartridge.
public export
data Backend = Universal | Custom String

||| Encode backend as integer for FFI.
export
backendToInt : Backend -> Int
backendToInt Universal   = 0
backendToInt (Custom _)  = 99

-- ---------------------------------------------------------------------------
-- MCP tool declarations
-- ---------------------------------------------------------------------------

||| Tools exposed via MCP protocol.
public export
data McpTool
  = ToolConnect
  | ToolDisconnect
  | ToolStatus
  | ToolInvoke
  | ToolList

||| Check if a tool requires an active session.
export
toolRequiresSession : McpTool -> Bool
toolRequiresSession ToolConnect    = False
toolRequiresSession ToolDisconnect = True
toolRequiresSession ToolStatus     = False
toolRequiresSession ToolInvoke     = True
toolRequiresSession ToolList       = False

||| Tool count for this cartridge.
export
toolCount : Nat
toolCount = 5
"#,
        pkg = pkg,
        domain_mod = domain_mod,
        name = cfg.name,
        ffi_name = ffi_name,
    )
}

/// Generate the Idris2 package file (.ipkg).
pub fn idris2_ipkg(cfg: &CartridgeConfig) -> String {
    let pkg = cfg.idris_package_name();
    let domain_mod = cfg.domain.idris_module_name();

    format!(
        r#"-- SPDX-License-Identifier: PMPL-1.0-or-later
package {lower_pkg}

version = "0.1.0"
authors = "Jonathan D.A. Jewell"
brief   = "{description}"

depends = base

modules = {pkg}.Safe{domain_mod}
"#,
        lower_pkg = cfg.name.replace('-', "_"),
        description = cfg.description,
        pkg = pkg,
        domain_mod = domain_mod,
    )
}

/// Generate the Zig FFI implementation ({name}_ffi.zig).
pub fn zig_ffi(cfg: &CartridgeConfig) -> String {
    let ffi_name = cfg.ffi_name();

    format!(
        r#"// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// {name}_ffi.zig — C-ABI FFI implementation for {name} cartridge.
//
// Implements the state machine defined in the Idris2 ABI layer.
// Thread-safe via std.Thread.Mutex. No heap allocations for results.

const std = @import("std");

// ---------------------------------------------------------------------------
// State machine (matches Idris2 ABI exactly)
// ---------------------------------------------------------------------------

pub const SessionState = enum(c_int) {{
    idle = 0,
    active = 1,
    processing = 2,
    err = 3,
}};

fn isValidTransition(from: SessionState, to: SessionState) bool {{
    return switch (from) {{
        .idle => to == .active,
        .active => to == .processing or to == .idle,
        .processing => to == .active or to == .err,
        .err => to == .idle,
    }};
}}

// ---------------------------------------------------------------------------
// Session slots (thread-safe, fixed-size pool)
// ---------------------------------------------------------------------------

const MAX_SESSIONS: usize = 16;
const BUF_SIZE: usize = 4096;

const SessionSlot = struct {{
    active: bool = false,
    state: SessionState = .idle,
    context_buf: [BUF_SIZE]u8 = undefined,
    context_len: usize = 0,
}};

var sessions: [MAX_SESSIONS]SessionSlot = [_]SessionSlot{{.{{}}}} ** MAX_SESSIONS;
var mutex: std.Thread.Mutex = .{{}};

// ---------------------------------------------------------------------------
// C-ABI exports
// ---------------------------------------------------------------------------

/// Check if a state transition is valid. Returns 1 (valid) or 0 (invalid).
pub export fn {ffi_name}_can_transition(from: c_int, to: c_int) c_int {{
    const f = std.meta.intToEnum(SessionState, from) catch return 0;
    const t = std.meta.intToEnum(SessionState, to) catch return 0;
    return if (isValidTransition(f, t)) 1 else 0;
}}

/// Open a new session. Returns slot index (>= 0) or error code (< 0).
/// Error codes: -1 = no free slots.
pub export fn {ffi_name}_session_open() c_int {{
    mutex.lock();
    defer mutex.unlock();

    for (&mut sessions, 0..) |*slot, idx| {{
        if (!slot.active) {{
            slot.active = true;
            slot.state = .active;
            slot.context_len = 0;
            return @intCast(idx);
        }}
    }}
    return -1; // No free slots
}}

/// Close a session. Returns 0 on success, -1 if slot invalid, -2 if bad transition.
pub export fn {ffi_name}_session_close(slot_idx: c_int) c_int {{
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .idle)) return -2;

    slot.active = false;
    slot.state = .idle;
    slot.context_len = 0;
    return 0;
}}

/// Get the current state of a session. Returns state int or -1 if invalid slot.
pub export fn {ffi_name}_session_state(slot_idx: c_int) c_int {{
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    const slot = &sessions[idx];
    if (!slot.active) return -1;
    return @intFromEnum(slot.state);
}}

/// Begin processing. Returns 0 on success, -1 if invalid slot, -2 if bad transition.
pub export fn {ffi_name}_begin_processing(slot_idx: c_int) c_int {{
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .processing)) return -2;

    slot.state = .processing;
    return 0;
}}

/// End processing (return to active). Returns 0 on success.
pub export fn {ffi_name}_end_processing(slot_idx: c_int) c_int {{
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .active)) return -2;

    slot.state = .active;
    return 0;
}}

/// Signal an error on a processing session. Returns 0 on success.
pub export fn {ffi_name}_signal_error(slot_idx: c_int) c_int {{
    mutex.lock();
    defer mutex.unlock();

    const idx: usize = std.math.cast(usize, slot_idx) orelse return -1;
    if (idx >= MAX_SESSIONS) return -1;
    var slot = &sessions[idx];
    if (!slot.active) return -1;
    if (!isValidTransition(slot.state, .err)) return -2;

    slot.state = .err;
    return 0;
}}

/// Reset all sessions (test/debug use only).
pub export fn {ffi_name}_reset() void {{
    mutex.lock();
    defer mutex.unlock();
    sessions = [_]SessionSlot{{.{{}}}} ** MAX_SESSIONS;
}}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "session lifecycle" {{
    {ffi_name}_reset();

    // Open a session
    const slot = {ffi_name}_session_open();
    try std.testing.expect(slot >= 0);

    // Should be in active state
    const state = {ffi_name}_session_state(slot);
    try std.testing.expectEqual(@as(c_int, 1), state); // active = 1

    // Begin processing
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_begin_processing(slot));
    try std.testing.expectEqual(@as(c_int, 2), {ffi_name}_session_state(slot)); // processing = 2

    // End processing
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_end_processing(slot));
    try std.testing.expectEqual(@as(c_int, 1), {ffi_name}_session_state(slot)); // active = 1

    // Close
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_session_close(slot));
}}

test "invalid transitions rejected" {{
    {ffi_name}_reset();

    const slot = {ffi_name}_session_open();
    try std.testing.expect(slot >= 0);

    // Can't go active -> error (must go through processing first)
    try std.testing.expectEqual(@as(c_int, -2), {ffi_name}_signal_error(slot));

    // Can't close while processing
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_begin_processing(slot));
    try std.testing.expectEqual(@as(c_int, -2), {ffi_name}_session_close(slot));
}}

test "transition validator" {{
    // Valid transitions
    try std.testing.expectEqual(@as(c_int, 1), {ffi_name}_can_transition(0, 1)); // idle -> active
    try std.testing.expectEqual(@as(c_int, 1), {ffi_name}_can_transition(1, 2)); // active -> processing
    try std.testing.expectEqual(@as(c_int, 1), {ffi_name}_can_transition(2, 1)); // processing -> active
    try std.testing.expectEqual(@as(c_int, 1), {ffi_name}_can_transition(2, 3)); // processing -> error
    try std.testing.expectEqual(@as(c_int, 1), {ffi_name}_can_transition(3, 0)); // error -> idle

    // Invalid transitions
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_can_transition(0, 2)); // idle -> processing
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_can_transition(1, 3)); // active -> error
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_can_transition(3, 1)); // error -> active

    // Out of range
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_can_transition(99, 0));
}}

test "slot exhaustion" {{
    {ffi_name}_reset();

    // Fill all slots
    var slots: [MAX_SESSIONS]c_int = undefined;
    for (&mut slots) |*s| {{
        s.* = {ffi_name}_session_open();
        try std.testing.expect(s.* >= 0);
    }}

    // Next open should fail
    try std.testing.expectEqual(@as(c_int, -1), {ffi_name}_session_open());

    // Free one and try again
    try std.testing.expectEqual(@as(c_int, 0), {ffi_name}_session_close(slots[0]));
    const new_slot = {ffi_name}_session_open();
    try std.testing.expect(new_slot >= 0);
}}
"#,
        name = cfg.name,
        ffi_name = ffi_name,
    )
}

/// Generate the Zig build.zig file.
pub fn zig_build(cfg: &CartridgeConfig) -> String {
    let ffi_name = cfg.ffi_name();

    format!(
        r#"// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>

const std = @import("std");

pub fn build(b: *std.Build) void {{
    const target = b.standardTargetOptions(.{{}});
    const optimize = b.standardOptimizeOption(.{{}});

    // Module
    const ffi_mod = b.addModule("{ffi_name}", .{{
        .root_source_file = b.path("{ffi_name}_ffi.zig"),
        .target = target,
        .optimize = optimize,
    }});

    // Shared library
    const lib = b.addLibrary(.{{
        .name = "{ffi_name}",
        .root_module = ffi_mod,
        .linkage = .dynamic,
    }});
    lib.linkLibC();
    b.installArtifact(lib);

    // Tests
    const tests = b.addTest(.{{
        .root_module = ffi_mod,
    }});
    tests.linkLibC();

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run FFI tests");
    test_step.dependOn(&run_tests.step);
}}
"#,
        ffi_name = ffi_name,
    )
}

/// Generate the V-lang adapter file ({name}_adapter.v).
pub fn vlang_adapter(cfg: &CartridgeConfig) -> String {
    let ffi_name = cfg.ffi_name();

    format!(
        r#"// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// {name}_adapter.v — V-lang REST/gRPC/GraphQL adapter for {name} cartridge.
//
// Bridges the Zig FFI C-ABI exports to the unified BoJ adapter protocol.

module {ffi_name}_adapter

// ---------------------------------------------------------------------------
// FFI declarations (from Zig shared library)
// ---------------------------------------------------------------------------

#flag -L../../ffi/zig-out/lib
#flag -l{ffi_name}

fn C.{ffi_name}_can_transition(from int, to int) int
fn C.{ffi_name}_session_open() int
fn C.{ffi_name}_session_close(slot_idx int) int
fn C.{ffi_name}_session_state(slot_idx int) int
fn C.{ffi_name}_begin_processing(slot_idx int) int
fn C.{ffi_name}_end_processing(slot_idx int) int
fn C.{ffi_name}_signal_error(slot_idx int) int
fn C.{ffi_name}_reset()

// ---------------------------------------------------------------------------
// Type definitions (matching Zig/Idris2 exactly)
// ---------------------------------------------------------------------------

enum SessionState {{
	idle       = 0
	active     = 1
	processing = 2
	err        = 3
}}

fn state_label(s int) string {{
	return match s {{
		0 {{ 'idle' }}
		1 {{ 'active' }}
		2 {{ 'processing' }}
		3 {{ 'error' }}
		else {{ 'unknown' }}
	}}
}}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

struct SessionResponse {{
	slot  int
	state string
}}

struct StateResponse {{
	slot  int
	state string
}}

struct TransitionResponse {{
	from    int
	to      int
	valid   bool
}}

// ---------------------------------------------------------------------------
// Adapter functions (REST API bridge)
// ---------------------------------------------------------------------------

pub fn session_open() !SessionResponse {{
	slot := C.{ffi_name}_session_open()
	if slot < 0 {{
		return error('no session slots available')
	}}
	return SessionResponse{{
		slot: slot
		state: 'active'
	}}
}}

pub fn session_close(slot int) !string {{
	result := C.{ffi_name}_session_close(slot)
	return match result {{
		0 {{ 'closed slot ${{slot}}' }}
		-1 {{ return error('slot ${{slot}} not active') }}
		-2 {{ return error('invalid state transition') }}
		else {{ return error('unknown error (code ${{result}})') }}
	}}
}}

pub fn session_state(slot int) StateResponse {{
	s := C.{ffi_name}_session_state(slot)
	return StateResponse{{ slot: slot, state: state_label(s) }}
}}

pub fn begin_processing(slot int) !string {{
	result := C.{ffi_name}_begin_processing(slot)
	return match result {{
		0 {{ 'processing on slot ${{slot}}' }}
		-1 {{ return error('slot ${{slot}} not active') }}
		-2 {{ return error('invalid state transition') }}
		else {{ return error('unknown error') }}
	}}
}}

pub fn end_processing(slot int) !string {{
	result := C.{ffi_name}_end_processing(slot)
	return match result {{
		0 {{ 'completed on slot ${{slot}}' }}
		-1 {{ return error('slot ${{slot}} not active') }}
		-2 {{ return error('invalid state transition') }}
		else {{ return error('unknown error') }}
	}}
}}

pub fn can_transition(from int, to int) TransitionResponse {{
	valid := C.{ffi_name}_can_transition(from, to) == 1
	return TransitionResponse{{ from: from, to: to, valid: valid }}
}}

pub fn reset() {{
	C.{ffi_name}_reset()
}}
"#,
        name = cfg.name,
        ffi_name = ffi_name,
    )
}

/// Generate the A2ML menu entry for this cartridge.
pub fn menu_entry(cfg: &CartridgeConfig) -> String {
    let protocols: Vec<&str> = cfg.protocols.iter().map(|p| p.a2ml_label()).collect();
    let proto_str = protocols.join(", ");

    format!(
        r#"
@cartridge(id="{name}"):
  name       = "{name}"
  version    = "{version}"
  status     = Development
  tier       = {tier:?}
  domain     = {domain}
  protocols  = [{protocols}]
  hash       = ""
  notes      = "{description}"
@end
"#,
        name = cfg.name,
        version = cfg.version,
        tier = cfg.tier,
        domain = cfg.domain,
        protocols = proto_str,
        description = cfg.description,
    )
}

/// Generate PanLL panel manifest (panels/manifest.json).
pub fn panel_manifest(cfg: &CartridgeConfig) -> String {
    let ffi_name = cfg.ffi_name();

    serde_json::to_string_pretty(&serde_json::json!({
        "$schema": "panll-harness/v1",
        "service_id": cfg.name,
        "service_name": format!("BoJ {} Cartridge", cfg.domain.idris_module_name()),
        "version": cfg.version,
        "protocol": "http",
        "default_endpoint": format!("http://localhost:7700/cartridge/{}", cfg.name),
        "health_check": {
            "path": format!("/cartridge/{}/health", cfg.name),
            "interval_ms": 30000,
            "timeout_ms": 5000,
            "healthy_threshold": 1,
            "unhealthy_threshold": 3
        },
        "data_sources": {
            format!("boj://cartridge/{}/status", cfg.name): {
                "path": format!("/cartridge/{}/status", cfg.name),
                "method": "GET",
                "returns": "SessionState",
                "description": "Current cartridge session state"
            },
            format!("boj://cartridge/{}/metrics", cfg.name): {
                "path": format!("/cartridge/{}/metrics", cfg.name),
                "method": "GET",
                "returns": "CartridgeMetrics",
                "description": "Cartridge operation metrics"
            },
            format!("boj://cartridge/{}/sessions", cfg.name): {
                "path": format!("/cartridge/{}/sessions", cfg.name),
                "method": "GET",
                "returns": "List SessionSlot",
                "description": "Active session slot details"
            }
        },
        "panels": [format!("panels/{}/panel.json", ffi_name)],
        "capabilities": cfg.protocols.iter().map(|p| p.a2ml_label()).collect::<Vec<_>>(),
        "clade": format!("boj/{}", cfg.domain.to_string().to_lowercase()),
        "integrations": {}
    }))
    .unwrap()
}

/// Generate PanLL panel definition (panels/{name}/panel.json).
pub fn panel_definition(cfg: &CartridgeConfig) -> String {
    let ffi_name = cfg.ffi_name();

    serde_json::to_string_pretty(&serde_json::json!({
        "$schema": "panll-panel/v1",
        "panel_id": format!("boj-{}", ffi_name),
        "name": format!("{} Status", cfg.domain.idris_module_name()),
        "description": format!("Management panel for {} cartridge", cfg.name),
        "version": cfg.version,
        "category": "boj-cartridge",
        "layout": {
            "type": "grid",
            "columns": 4,
            "rows": 3,
            "gap": "8px"
        },
        "widgets": [
            {
                "id": "status",
                "type": "status-indicator",
                "position": { "col": 1, "row": 1, "span_cols": 1, "span_rows": 1 },
                "label": "Cartridge Status",
                "data_source": format!("boj://cartridge/{}/status", cfg.name),
                "states": {
                    "idle": { "color": "#6b7280", "icon": "circle-pause" },
                    "active": { "color": "#22c55e", "icon": "circle-check" },
                    "processing": { "color": "#3b82f6", "icon": "loader" },
                    "error": { "color": "#ef4444", "icon": "circle-x" }
                }
            },
            {
                "id": "sessions",
                "type": "counter",
                "position": { "col": 2, "row": 1, "span_cols": 1, "span_rows": 1 },
                "label": "Active Sessions",
                "data_source": format!("boj://cartridge/{}/sessions", cfg.name),
                "format": "number"
            },
            {
                "id": "metrics",
                "type": "table",
                "position": { "col": 1, "row": 2, "span_cols": 4, "span_rows": 2 },
                "label": "Session Details",
                "data_source": format!("boj://cartridge/{}/sessions", cfg.name),
                "columns": ["slot", "state", "context_len"]
            }
        ],
        "refresh_interval_ms": 2000,
        "permissions": [
            format!("read:{}", ffi_name),
            format!("invoke:{}", ffi_name)
        ]
    }))
    .unwrap()
}

/// Generate the minter.toml config file.
pub fn minter_toml(cfg: &CartridgeConfig) -> String {
    toml::to_string_pretty(cfg).unwrap_or_else(|_| String::from("# Failed to serialise config"))
}

/// Generate a README.adoc for the cartridge.
pub fn readme(cfg: &CartridgeConfig) -> String {
    let proto_list: Vec<&str> = cfg.protocols.iter().map(|p| p.a2ml_label()).collect();

    format!(
        r#"= {name}
Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
:spdx: PMPL-1.0-or-later
:tier: {tier:?}
:domain: {domain}
:protocols: {protocols}

== Overview

{description}

== Architecture

[cols="1,1,2"]
|===
| Layer | Language | Purpose

| ABI
| Idris2
| Formally verified state machine with dependent-type proofs

| FFI
| Zig
| C-compatible implementation with thread-safe session pool

| Adapter
| V-lang
| REST/gRPC/GraphQL bridge to BoJ unified adapter
|===

== Building

[source,bash]
----
# Build FFI shared library
cd ffi && zig build

# Run FFI tests
cd ffi && zig build test

# Type-check ABI
cd abi && idris2 --check {pkg}.Safe{domain_mod}
----

== Status

Development — not yet ready for mounting.
"#,
        name = cfg.name,
        tier = cfg.tier,
        domain = cfg.domain,
        protocols = proto_list.join(", "),
        description = cfg.description,
        pkg = cfg.idris_package_name(),
        domain_mod = cfg.domain.idris_module_name(),
    )
}
