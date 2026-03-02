// SPDX-License-Identifier: PMPL-1.0-or-later
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
export fn nesy_harmonize(neural: c_int, symbolic: c_int) c_int {
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
export fn nesy_confidence(neural: c_int, symbolic: c_int) c_int {
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
