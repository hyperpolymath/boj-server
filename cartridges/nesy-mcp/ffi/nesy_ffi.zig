// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// NeSy-MCP Cartridge — Zig FFI bridge for neurosymbolic harmonization.
//
// Implements the harmonization law: Symbolic truth always overrides
// Neural probability. This is the runtime bridge between Hypatia's
// neural predictions and Echidna's symbolic proofs.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types (must match NesyMcp.SafeReasoning encodings)
// ═══════════════════════════════════════════════════════════════════════

pub const NeuralVerdict = enum(c_int) {
    probable_safe = 1,
    unsure = 2,
    probable_unsafe = 3,
};

pub const SymbolicVerdict = enum(c_int) {
    proven_safe = 1,
    no_proof = 2,
    proven_unsafe = 3,
};

pub const HarmonizedVerdict = enum(c_int) {
    certified_safe = 1,
    requires_review = 2,
    critical_unsafe = 3,
};

pub const ConfidenceLevel = enum(c_int) {
    low = 1,
    high = 2,
    absolute = 3,
};

// ═══════════════════════════════════════════════════════════════════════
// Harmonization
// ═══════════════════════════════════════════════════════════════════════

/// The harmonization law.
/// Symbolic truth ALWAYS overrides Neural probability.
pub export fn nesy_harmonize(neural: c_int, symbolic: c_int) c_int {
    const sym: SymbolicVerdict = @enumFromInt(symbolic);
    const neur: NeuralVerdict = @enumFromInt(neural);

    const result: HarmonizedVerdict = switch (sym) {
        .proven_unsafe => .critical_unsafe,
        .proven_safe => .certified_safe,
        .no_proof => switch (neur) {
            .probable_unsafe => .critical_unsafe,
            .unsure => .requires_review,
            .probable_safe => .requires_review,
        },
    };

    return @intFromEnum(result);
}

/// Confidence level for a harmonization.
pub export fn nesy_confidence(neural: c_int, symbolic: c_int) c_int {
    const sym: SymbolicVerdict = @enumFromInt(symbolic);
    const neur: NeuralVerdict = @enumFromInt(neural);

    const result: ConfidenceLevel = switch (sym) {
        .proven_safe, .proven_unsafe => .absolute,
        .no_proof => switch (neur) {
            .probable_unsafe => .high,
            .unsure, .probable_safe => .low,
        },
    };

    return @intFromEnum(result);
}


// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface (loader expects these 4 C-ABI symbols)
// ═══════════════════════════════════════════════════════════════════════

/// Initialise the nesy-mcp cartridge. No-op (harmonization is stateless).
pub export fn boj_cartridge_init() c_int {
    return 0;
}

/// Deinitialise the nesy-mcp cartridge. No-op (harmonization is stateless).
pub export fn boj_cartridge_deinit() void {}

/// Return the cartridge name as a null-terminated C string.
pub export fn boj_cartridge_name() [*:0]const u8 {
    return "nesy-mcp";
}

/// Return the cartridge version as a null-terminated C string.
pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.2.0";
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 dispatch (boj_cartridge_invoke, 5th standard symbol)
// ═══════════════════════════════════════════════════════════════════════

const shim = @import("cartridge_shim.zig");

/// Dispatch the cartridge.json MCP tools. Grade D Alpha — each arm
/// returns a stub JSON body shaped to the tool's intended response.
export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    _ = json_args;
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const body: []const u8 =     if (shim.toolIs(tool_name, "nesy_harmonize"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "nesy_analyze_drift"))
        "{\"result\":{\"status\":\"stub\"}}"
    else if (shim.toolIs(tool_name, "nesy_reasoning_mode_info"))
        "{\"result\":{\"metadata\":{},\"status\":\"stub\"}}"
else
    return shim.RC_UNKNOWN_TOOL;

    return shim.writeResult(out_buf, in_out_len, body);
}

// ═══════════════════════════════════════════════════════════════════════
// Protocol Types (from proven-nesy, added in v0.2.0)
// ═══════════════════════════════════════════════════════════════════════

pub const ReasoningMode = enum(c_int) {
    symbolic = 0,
    neural = 1,
    sym_to_neural = 2,
    neural_to_sym = 3,
    ensemble = 4,
    cascade = 5,
};

pub const DriftKind = enum(c_int) {
    no_drift = 0,
    semantic_drift = 1,
    confidence_drift = 2,
    factual_drift = 3,
    temporal_drift = 4,
    catastrophic_drift = 5,
};

pub const DriftAction = enum(c_int) {
    log_and_accept = 0,
    flag_for_review = 1,
    reject_neural = 2,
    retry_neural = 3,
    escalate = 4,
    halt = 5,
};

pub const MergeStrategy = enum(c_int) {
    symbolic_primacy = 0,
    neural_primacy = 1,
    confidence_weighted = 2,
    consensus = 3,
    dual_return = 4,
    constrained_generation = 5,
};

pub const GroundingStatus = enum(c_int) {
    fully_grounded = 0,
    partially_grounded = 1,
    ungrounded = 2,
    grounding_pending = 3,
    grounding_failed = 4,
};

/// Recommend a drift action given drift severity.
pub export fn nesy_recommend_drift_action(drift: c_int) c_int {
    const dk: DriftKind = @enumFromInt(drift);
    const action: DriftAction = switch (dk) {
        .no_drift, .semantic_drift => .log_and_accept,
        .confidence_drift => .flag_for_review,
        .factual_drift => .reject_neural,
        .temporal_drift => .retry_neural,
        .catastrophic_drift => .halt,
    };
    return @intFromEnum(action);
}

/// Whether a reasoning mode uses the symbolic layer.
pub export fn nesy_mode_uses_symbolic(mode: c_int) c_int {
    const m: ReasoningMode = @enumFromInt(mode);
    return if (m != .neural) 1 else 0;
}

/// Whether a reasoning mode uses the neural layer.
pub export fn nesy_mode_uses_neural(mode: c_int) c_int {
    const m: ReasoningMode = @enumFromInt(mode);
    return if (m != .symbolic) 1 else 0;
}

/// Whether a grounding status is trusted (fully grounded).
pub export fn nesy_grounding_is_trusted(g: c_int) c_int {
    const gs: GroundingStatus = @enumFromInt(g);
    return if (gs == .fully_grounded) 1 else 0;
}

/// Whether the drift is urgent (factual or catastrophic).
pub export fn nesy_drift_is_urgent(drift: c_int) c_int {
    const dk: DriftKind = @enumFromInt(drift);
    return switch (dk) {
        .factual_drift, .catastrophic_drift => 1,
        else => 0,
    };
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "symbolic proven unsafe always wins" {
    // Even if neural says safe, symbolic unsafe = critical
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(HarmonizedVerdict.critical_unsafe)),
        nesy_harmonize(@intFromEnum(NeuralVerdict.probable_safe), @intFromEnum(SymbolicVerdict.proven_unsafe)),
    );
}

test "symbolic proven safe always wins" {
    // Even if neural says unsafe, symbolic safe = certified
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(HarmonizedVerdict.certified_safe)),
        nesy_harmonize(@intFromEnum(NeuralVerdict.probable_unsafe), @intFromEnum(SymbolicVerdict.proven_safe)),
    );
}

test "no proof + probable safe = requires review" {
    // Neural confidence without proof is just a guess
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(HarmonizedVerdict.requires_review)),
        nesy_harmonize(@intFromEnum(NeuralVerdict.probable_safe), @intFromEnum(SymbolicVerdict.no_proof)),
    );
}

test "no proof + probable unsafe = critical" {
    // Neural alarm without proof = escalate
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(HarmonizedVerdict.critical_unsafe)),
        nesy_harmonize(@intFromEnum(NeuralVerdict.probable_unsafe), @intFromEnum(SymbolicVerdict.no_proof)),
    );
}

test "proof gives absolute confidence" {
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(ConfidenceLevel.absolute)),
        nesy_confidence(@intFromEnum(NeuralVerdict.unsure), @intFromEnum(SymbolicVerdict.proven_safe)),
    );
}

test "no proof gives low confidence" {
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(ConfidenceLevel.low)),
        nesy_confidence(@intFromEnum(NeuralVerdict.probable_safe), @intFromEnum(SymbolicVerdict.no_proof)),
    );
}

// Protocol tests (v0.2.0)

test "drift action recommendations" {
    try std.testing.expectEqual(@as(c_int, 0), nesy_recommend_drift_action(0)); // no_drift -> log_and_accept
    try std.testing.expectEqual(@as(c_int, 2), nesy_recommend_drift_action(3)); // factual -> reject_neural
    try std.testing.expectEqual(@as(c_int, 5), nesy_recommend_drift_action(5)); // catastrophic -> halt
}

test "reasoning mode predicates" {
    try std.testing.expectEqual(@as(c_int, 1), nesy_mode_uses_symbolic(0)); // symbolic uses symbolic
    try std.testing.expectEqual(@as(c_int, 0), nesy_mode_uses_symbolic(1)); // neural does not
    try std.testing.expectEqual(@as(c_int, 0), nesy_mode_uses_neural(0)); // symbolic does not use neural
    try std.testing.expectEqual(@as(c_int, 1), nesy_mode_uses_neural(4)); // ensemble uses neural
}

test "drift urgency" {
    try std.testing.expectEqual(@as(c_int, 0), nesy_drift_is_urgent(0)); // no_drift not urgent
    try std.testing.expectEqual(@as(c_int, 1), nesy_drift_is_urgent(3)); // factual is urgent
    try std.testing.expectEqual(@as(c_int, 1), nesy_drift_is_urgent(5)); // catastrophic is urgent
}

// ═══════════════════════════════════════════════════════════════════════
// ADR-0006 invoke dispatch tests
// ═══════════════════════════════════════════════════════════════════════

test "invoke: each declared tool succeeds" {
    var buf: [256]u8 = undefined;
    const tools = [_][]const u8{
        "nesy_harmonize",
        "nesy_analyze_drift",
        "nesy_reasoning_mode_info",
    };
    for (tools) |t| {
        var len: usize = buf.len;
        const rc = boj_cartridge_invoke(t.ptr, "{}", &buf, &len);
        try std.testing.expectEqual(@as(i32, 0), rc);
        try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "result") != null);
    }
}

test "invoke: unknown tool returns -1" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nope", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -1), rc);
}

test "invoke: buffer too small returns -3" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nesy_harmonize", "{}", &buf, &len);
    try std.testing.expectEqual(@as(i32, -3), rc);
    try std.testing.expect(len > 4);
}
