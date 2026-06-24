// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// ABI Verification Instrument — Exhaustive boundary tests for the Zig FFI.
//
// This file is the runtime complement to abi_axioms.zig:
//
//   abi_axioms.zig  — declares constants; proves static/cross invariants at
//                     compile time (theorems in the mathematical sense).
//   abi_verify.zig  — cross-checks axioms against live Zig types (comptime),
//                     then exhaustively exercises every ABI boundary (runtime).
//
// Structure:
//   §A  Cross-module comptime proofs   (fail to COMPILE if violated)
//   §B  Catalogue boundary tests        (fail at RUNTIME if violated)
//   §C  Cartridge invoke ABI tests      (writeResult / toolIs / invokeArgsNull)
//   §D  Hash/Loader boundary tests
//   §E  Safety boundary tests
//   §F  Thread-safety spot check
//
// How to read the trust labels:
//   [THEOREM]  Proven by this comptime block — true iff code compiles.
//   [TEST]     Proven by this runtime test — true for all covered inputs.
//   [BOUNDARY] This test is specifically exercising the limit value.
//   [GAP]      Known gap: what is NOT proven here and why.

const std = @import("std");
const axioms = @import("abi_axioms.zig");
const catalogue = @import("catalogue");
const safety = @import("safety");
const shim = @import("cartridge_shim");
// loader is intentionally NOT imported here.  loader.zig uses @import("catalogue.zig")
// (a relative-path import) internally, which conflicts with the named `catalogue` module
// when both are included in the same test compilation.  The loader's hash constants
// (HASH_LEN, HASH_HEX_LEN) are axiomatically declared in abi_axioms.zig and cross-checked
// there via comptime.  See §A.6 below for the documented gap.

// ═══════════════════════════════════════════════════════════════════════════
// §A  Cross-module comptime proofs
// ═══════════════════════════════════════════════════════════════════════════
//
// These blocks run at COMPILE TIME.  A violation causes a compile error with
// the axiom ID.  They cannot be disabled or skipped by the test runner.

comptime {
    // ─── A.1  CartridgeStatus encoding matches axioms ──────────────────────
    // [THEOREM] If CartridgeStatus drifts from the C header, this block fails.
    if (@intFromEnum(catalogue.CartridgeStatus.development) != axioms.STATUS_DEVELOPMENT)
        @compileError("cv.A.1: CartridgeStatus.development != axioms.STATUS_DEVELOPMENT");
    if (@intFromEnum(catalogue.CartridgeStatus.ready) != axioms.STATUS_READY)
        @compileError("cv.A.1: CartridgeStatus.ready != axioms.STATUS_READY");
    if (@intFromEnum(catalogue.CartridgeStatus.deprecated) != axioms.STATUS_DEPRECATED)
        @compileError("cv.A.1: CartridgeStatus.deprecated != axioms.STATUS_DEPRECATED");
    if (@intFromEnum(catalogue.CartridgeStatus.faulty) != axioms.STATUS_FAULTY)
        @compileError("cv.A.1: CartridgeStatus.faulty != axioms.STATUS_FAULTY");

    // ─── A.2  ProtocolType encoding matches axioms ─────────────────────────
    if (@intFromEnum(catalogue.ProtocolType.mcp) != axioms.PROTO_MCP)
        @compileError("cv.A.2: ProtocolType.mcp != axioms.PROTO_MCP");
    if (@intFromEnum(catalogue.ProtocolType.lsp) != axioms.PROTO_LSP)
        @compileError("cv.A.2: ProtocolType.lsp != axioms.PROTO_LSP");
    if (@intFromEnum(catalogue.ProtocolType.dap) != axioms.PROTO_DAP)
        @compileError("cv.A.2: ProtocolType.dap != axioms.PROTO_DAP");
    if (@intFromEnum(catalogue.ProtocolType.bsp) != axioms.PROTO_BSP)
        @compileError("cv.A.2: ProtocolType.bsp != axioms.PROTO_BSP");
    if (@intFromEnum(catalogue.ProtocolType.nesy) != axioms.PROTO_NESY)
        @compileError("cv.A.2: ProtocolType.nesy != axioms.PROTO_NESY");
    if (@intFromEnum(catalogue.ProtocolType.agentic) != axioms.PROTO_AGENTIC)
        @compileError("cv.A.2: ProtocolType.agentic != axioms.PROTO_AGENTIC");
    if (@intFromEnum(catalogue.ProtocolType.fleet) != axioms.PROTO_FLEET)
        @compileError("cv.A.2: ProtocolType.fleet != axioms.PROTO_FLEET");
    if (@intFromEnum(catalogue.ProtocolType.grpc) != axioms.PROTO_GRPC)
        @compileError("cv.A.2: ProtocolType.grpc != axioms.PROTO_GRPC");
    if (@intFromEnum(catalogue.ProtocolType.rest) != axioms.PROTO_REST)
        @compileError("cv.A.2: ProtocolType.rest != axioms.PROTO_REST");

    // ─── A.3  CapabilityDomain encoding matches axioms ────────────────────
    if (@intFromEnum(catalogue.CapabilityDomain.cloud) != axioms.DOMAIN_CLOUD)
        @compileError("cv.A.3: CapabilityDomain.cloud != axioms.DOMAIN_CLOUD");
    if (@intFromEnum(catalogue.CapabilityDomain.container) != axioms.DOMAIN_CONTAINER)
        @compileError("cv.A.3: CapabilityDomain.container != axioms.DOMAIN_CONTAINER");
    if (@intFromEnum(catalogue.CapabilityDomain.database) != axioms.DOMAIN_DATABASE)
        @compileError("cv.A.3: CapabilityDomain.database != axioms.DOMAIN_DATABASE");
    if (@intFromEnum(catalogue.CapabilityDomain.k8s) != axioms.DOMAIN_K8S)
        @compileError("cv.A.3: CapabilityDomain.k8s != axioms.DOMAIN_K8S");
    if (@intFromEnum(catalogue.CapabilityDomain.git) != axioms.DOMAIN_GIT)
        @compileError("cv.A.3: CapabilityDomain.git != axioms.DOMAIN_GIT");
    if (@intFromEnum(catalogue.CapabilityDomain.secrets) != axioms.DOMAIN_SECRETS)
        @compileError("cv.A.3: CapabilityDomain.secrets != axioms.DOMAIN_SECRETS");
    if (@intFromEnum(catalogue.CapabilityDomain.code_intel) != axioms.DOMAIN_CODE_INTEL)
        @compileError("cv.A.3: CapabilityDomain.code_intel != axioms.DOMAIN_CODE_INTEL");

    // ─── A.4  MenuTier encoding matches axioms ────────────────────────────
    if (@intFromEnum(catalogue.MenuTier.teranga) != axioms.TIER_TERANGA)
        @compileError("cv.A.4: MenuTier.teranga != axioms.TIER_TERANGA");
    if (@intFromEnum(catalogue.MenuTier.shield) != axioms.TIER_SHIELD)
        @compileError("cv.A.4: MenuTier.shield != axioms.TIER_SHIELD");
    if (@intFromEnum(catalogue.MenuTier.ayo) != axioms.TIER_AYO)
        @compileError("cv.A.4: MenuTier.ayo != axioms.TIER_AYO");

    // ─── A.5  Cartridge invoke return codes match axioms ──────────────────
    // shim.RC_* are i32; axioms.RC_* are comptime_int — comparison is direct.
    if (shim.RC_SUCCESS != axioms.RC_SUCCESS)
        @compileError("cv.A.5: shim.RC_SUCCESS != axioms.RC_SUCCESS");
    if (shim.RC_UNKNOWN_TOOL != axioms.RC_UNKNOWN_TOOL)
        @compileError("cv.A.5: shim.RC_UNKNOWN_TOOL != axioms.RC_UNKNOWN_TOOL");
    if (shim.RC_BAD_ARGS != axioms.RC_BAD_ARGS)
        @compileError("cv.A.5: shim.RC_BAD_ARGS != axioms.RC_BAD_ARGS");
    if (shim.RC_BUFFER_TOO_SMALL != axioms.RC_BUFFER_TOO_SMALL)
        @compileError("cv.A.5: shim.RC_BUFFER_TOO_SMALL != axioms.RC_BUFFER_TOO_SMALL");
    if (shim.RC_RUNTIME_ERROR != axioms.RC_RUNTIME_ERROR)
        @compileError("cv.A.5: shim.RC_RUNTIME_ERROR != axioms.RC_RUNTIME_ERROR");
    if (shim.RC_PANIC != axioms.RC_PANIC)
        @compileError("cv.A.5: shim.RC_PANIC != axioms.RC_PANIC");
    if (shim.RC_AUTH_DENIED != axioms.RC_AUTH_DENIED)
        @compileError("cv.A.5: shim.RC_AUTH_DENIED != axioms.RC_AUTH_DENIED");

    // ─── A.6  [GAP] Loader hash constants ────────────────────────────────
    // loader.HASH_LEN and loader.HASH_HEX_LEN cannot be cross-checked here because
    // importing the `loader` module in the same compilation as `catalogue` causes a
    // "file exists in multiple modules" error (loader.zig uses @import("catalogue.zig")
    // internally, conflicting with the named `catalogue` module).
    //
    // Mitigation: abi_axioms.zig declares HASH_LEN=32 and HASH_HEX_LEN=64, and
    // proves HASH_HEX_LEN == HASH_LEN * 2 at comptime (ax.3.1).  loader.zig's own
    // tests (run via `zig build loader`) validate the same constants independently.
    // The gap is the missing CROSS-CHECKED theorem "loader module agrees with axioms".
    //
    // Tracked: resolve when loader.zig is updated to use named-module import
    // (@import("catalogue") via loader_mod.addImport) instead of @import("catalogue.zig").

    // ─── A.7  SafetyError enum values match axioms ────────────────────────
    if (@intFromEnum(safety.SafetyError.safe) != axioms.SAFETY_SAFE)
        @compileError("cv.A.7: SafetyError.safe != axioms.SAFETY_SAFE");
    if (@intFromEnum(safety.SafetyError.empty) != axioms.SAFETY_EMPTY)
        @compileError("cv.A.7: SafetyError.empty != axioms.SAFETY_EMPTY");
    if (@intFromEnum(safety.SafetyError.shell_injection) != axioms.SAFETY_SHELL_INJECTION)
        @compileError("cv.A.7: SafetyError.shell_injection != axioms.SAFETY_SHELL_INJECTION");
    if (@intFromEnum(safety.SafetyError.sql_injection) != axioms.SAFETY_SQL_INJECTION)
        @compileError("cv.A.7: SafetyError.sql_injection != axioms.SAFETY_SQL_INJECTION");
    if (@intFromEnum(safety.SafetyError.path_traversal) != axioms.SAFETY_PATH_TRAVERSAL)
        @compileError("cv.A.7: SafetyError.path_traversal != axioms.SAFETY_PATH_TRAVERSAL");
    if (@intFromEnum(safety.SafetyError.too_long) != axioms.SAFETY_TOO_LONG)
        @compileError("cv.A.7: SafetyError.too_long != axioms.SAFETY_TOO_LONG");
    if (@intFromEnum(safety.SafetyError.null_byte) != axioms.SAFETY_NULL_BYTE)
        @compileError("cv.A.7: SafetyError.null_byte != axioms.SAFETY_NULL_BYTE");
    if (@intFromEnum(safety.SafetyError.control_char) != axioms.SAFETY_CONTROL_CHAR)
        @compileError("cv.A.7: SafetyError.control_char != axioms.SAFETY_CONTROL_CHAR");
    if (@intFromEnum(safety.SafetyError.invalid_url) != axioms.SAFETY_INVALID_URL)
        @compileError("cv.A.7: SafetyError.invalid_url != axioms.SAFETY_INVALID_URL");
    if (@intFromEnum(safety.SafetyError.json_unsafe) != axioms.SAFETY_JSON_UNSAFE)
        @compileError("cv.A.7: SafetyError.json_unsafe != axioms.SAFETY_JSON_UNSAFE");
}

// [GAP] Private constants in catalogue.zig (MAX_CARTRIDGES=128, MAX_ORDER_SIZE=16)
// cannot be proven via comptime cross-check.  They are verified at runtime in §B
// by filling the registry to capacity.

// [GAP] Private constants in safety.zig (MAX_SHELL_ARG_LEN=4096, MAX_PATH_LEN=4096)
// cannot be proven via comptime cross-check (not pub).  axioms.MAX_SHELL_ARG and
// axioms.MAX_PATH are [ASSUMED] to match.  Safety tests in §E verify the limit
// indirectly by constructing inputs of exactly that length.

// ═══════════════════════════════════════════════════════════════════════════
// §B  Catalogue boundary tests
// ═══════════════════════════════════════════════════════════════════════════
//
// Each test is self-contained: begins with an explicit deinit+init pair and
// ends with a deferred deinit.  This prevents state leaking between tests
// regardless of execution order.

// Convenience: register a single cartridge with "ready" status and minimal fields.
fn registerReady(name: []const u8) c_int {
    return catalogue.boj_catalogue_register(
        name.ptr, name.len,
        "1.0".ptr, 3,
        axioms.STATUS_READY, // ready
        axioms.TIER_TERANGA, // teranga
        axioms.DOMAIN_CLOUD, // cloud
    );
}

// Convenience: register a cartridge with a given status integer.
fn registerStatus(name: []const u8, status: c_int) c_int {
    return catalogue.boj_catalogue_register(
        name.ptr, name.len,
        "1.0".ptr, 3,
        status,
        axioms.TIER_TERANGA,
        axioms.DOMAIN_CLOUD,
    );
}

test "B.1: pre-init guard — register fails before init" {
    // Force uninitialized state.
    catalogue.boj_catalogue_deinit();
    try std.testing.expectEqual(@as(c_int, axioms.CAT_ERR), registerReady("alpha"));
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());
}

test "B.2: init is idempotent — double-init resets and succeeds" {
    catalogue.boj_catalogue_deinit();
    defer catalogue.boj_catalogue_deinit();
    try std.testing.expectEqual(@as(c_int, axioms.CAT_OK), catalogue.boj_catalogue_init());
    // Register one cartridge, then re-init — count resets to 0.
    _ = registerReady("ephemeral");
    try std.testing.expectEqual(@as(usize, 1), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(c_int, axioms.CAT_OK), catalogue.boj_catalogue_init());
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());
}

test "B.3: [BOUNDARY] capacity at exactly MAX_CARTRIDGES fills without error" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Register exactly MAX_CARTRIDGES entries.  Each name is "c000".."c127".
    var i: usize = 0;
    while (i < axioms.MAX_CARTRIDGES) : (i += 1) {
        var name_buf: [8]u8 = undefined;
        const n = std.fmt.bufPrint(&name_buf, "c{d:0>3}", .{i}) catch unreachable;
        try std.testing.expectEqual(
            @as(c_int, axioms.CAT_OK),
            registerReady(n),
        );
    }
    try std.testing.expectEqual(@as(usize, axioms.MAX_CARTRIDGES), catalogue.boj_catalogue_count());

    // One more must fail.
    const rc = registerReady("overflow");
    try std.testing.expectEqual(@as(c_int, axioms.CAT_ERR), rc);
    try std.testing.expectEqual(@as(usize, axioms.MAX_CARTRIDGES), catalogue.boj_catalogue_count());
}

test "B.4: [BOUNDARY] mount gate — only STATUS_READY passes" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Register one entry for each status value.
    const statuses = [_]c_int{
        axioms.STATUS_DEVELOPMENT,
        axioms.STATUS_READY,
        axioms.STATUS_DEPRECATED,
        axioms.STATUS_FAULTY,
    };
    const names = [_][]const u8{ "dev", "rdy", "dep", "flt" };
    for (statuses, names, 0..) |st, nm, idx| {
        _ = registerStatus(nm, st);
        const rc = catalogue.boj_catalogue_mount(idx);
        if (st == axioms.MOUNT_GATE_STATUS) {
            try std.testing.expectEqual(@as(c_int, axioms.CAT_OK), rc);
            try std.testing.expectEqual(@as(c_int, axioms.CAT_MOUNTED),
                catalogue.boj_catalogue_is_mounted(idx));
        } else {
            try std.testing.expectEqual(@as(c_int, axioms.CAT_ERR), rc);
            try std.testing.expectEqual(@as(c_int, axioms.CAT_UNMOUNTED),
                catalogue.boj_catalogue_is_mounted(idx));
        }
    }
}

test "B.5: [BOUNDARY] name length at exactly NAME_MAX" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Name of exactly 64 bytes must succeed.
    const name64 = "a" ** axioms.NAME_MAX;
    try std.testing.expectEqual(
        @as(c_int, axioms.CAT_OK),
        catalogue.boj_catalogue_register(name64.ptr, name64.len, "1.0".ptr, 3, axioms.STATUS_READY, 0, 1),
    );
    try std.testing.expectEqual(@as(usize, 1), catalogue.boj_catalogue_count());
}

test "B.6: [BOUNDARY] name length exceeding NAME_MAX fails" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Name of 65 bytes must fail.
    const name65 = "b" ** (axioms.NAME_MAX + 1);
    try std.testing.expectEqual(
        @as(c_int, axioms.CAT_ERR),
        catalogue.boj_catalogue_register(name65.ptr, name65.len, "1.0".ptr, 3, axioms.STATUS_READY, 0, 1),
    );
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());
}

test "B.7: [BOUNDARY] version length at exactly VERSION_MAX" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const ver16 = "v" ** axioms.VERSION_MAX;
    try std.testing.expectEqual(
        @as(c_int, axioms.CAT_OK),
        catalogue.boj_catalogue_register("myc".ptr, 3, ver16.ptr, ver16.len, axioms.STATUS_READY, 0, 1),
    );
}

test "B.8: [BOUNDARY] version length exceeding VERSION_MAX fails" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    const ver17 = "v" ** (axioms.VERSION_MAX + 1);
    try std.testing.expectEqual(
        @as(c_int, axioms.CAT_ERR),
        catalogue.boj_catalogue_register("myc".ptr, 3, ver17.ptr, ver17.len, axioms.STATUS_READY, 0, 1),
    );
}

test "B.9: [BOUNDARY] protocol range — PROTO_MIN and PROTO_MAX accepted" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = registerReady("proto-cart");
    // PROTO_MIN (1 = MCP) and PROTO_MAX (9 = REST) must both be accepted.
    try std.testing.expectEqual(@as(c_int, axioms.CAT_OK),
        catalogue.boj_catalogue_add_protocol(axioms.PROTO_MIN));
    try std.testing.expectEqual(@as(c_int, axioms.CAT_OK),
        catalogue.boj_catalogue_add_protocol(axioms.PROTO_MAX));
}

test "B.10: [BOUNDARY] protocol values outside [PROTO_MIN, PROTO_MAX] fail" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = registerReady("proto-cart2");
    // 0 and PROTO_MAX+1 must be rejected.
    try std.testing.expectEqual(@as(c_int, axioms.CAT_ERR),
        catalogue.boj_catalogue_add_protocol(axioms.PROTO_MIN - 1));
    try std.testing.expectEqual(@as(c_int, axioms.CAT_ERR),
        catalogue.boj_catalogue_add_protocol(axioms.PROTO_MAX + 1));
}

test "B.11: index boundary — out-of-range access returns CAT_NOT_FOUND" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = registerReady("single");
    // count == 1; index == 1 is out of range.
    try std.testing.expectEqual(@as(c_int, axioms.CAT_NOT_FOUND),
        catalogue.boj_catalogue_mount(1));
    try std.testing.expectEqual(@as(c_int, axioms.CAT_NOT_FOUND),
        catalogue.boj_catalogue_unmount(1));
    try std.testing.expectEqual(@as(c_int, axioms.CAT_IS_MOUNTED_ERR),
        catalogue.boj_catalogue_is_mounted(1));
}

test "B.12: [BOUNDARY] order validation at MAX_ORDER_SIZE" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    // Register MAX_ORDER_SIZE ready cartridges.
    var name_bufs: [axioms.MAX_ORDER_SIZE][8]u8 = undefined;
    var name_ptrs: [axioms.MAX_ORDER_SIZE][*]const u8 = undefined;
    var name_lens: [axioms.MAX_ORDER_SIZE]usize = undefined;

    var i: usize = 0;
    while (i < axioms.MAX_ORDER_SIZE) : (i += 1) {
        const n = std.fmt.bufPrint(&name_bufs[i], "ord{d:0>2}", .{i}) catch unreachable;
        _ = registerReady(n);
        name_ptrs[i] = name_bufs[i][0..n.len].ptr;
        name_lens[i] = n.len;
    }

    // All MAX_ORDER_SIZE should be satisfied.
    try std.testing.expectEqual(
        @as(usize, axioms.MAX_ORDER_SIZE),
        catalogue.boj_menu_validate_order(&name_ptrs, &name_lens, axioms.MAX_ORDER_SIZE),
    );

    // MAX_ORDER_SIZE + 1 returns 0 (clamped; count exceeds limit).
    try std.testing.expectEqual(
        @as(usize, 0),
        catalogue.boj_menu_validate_order(&name_ptrs, &name_lens, axioms.MAX_ORDER_SIZE + 1),
    );
}

test "B.13: [BOUNDARY] backend label at exactly BACKEND_MAX" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = registerReady("backend-cart");
    const lbl32 = "x" ** axioms.BACKEND_MAX;
    try std.testing.expectEqual(@as(c_int, axioms.CAT_OK),
        catalogue.boj_catalogue_set_backend(lbl32.ptr, lbl32.len));

    var out: [axioms.BACKEND_MAX]u8 = undefined;
    const got = catalogue.boj_menu_backend(0, &out, axioms.BACKEND_MAX);
    try std.testing.expectEqual(@as(usize, axioms.BACKEND_MAX), got);
    try std.testing.expectEqualSlices(u8, lbl32, out[0..got]);
}

test "B.14: [BOUNDARY] backend label exceeding BACKEND_MAX fails" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    _ = registerReady("backend-cart2");
    const lbl33 = "x" ** (axioms.BACKEND_MAX + 1);
    try std.testing.expectEqual(@as(c_int, axioms.CAT_ERR),
        catalogue.boj_catalogue_set_backend(lbl33.ptr, lbl33.len));
}

test "B.15: deinit clears mounted state — post-deinit count is 0" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();

    _ = registerReady("persistent");
    _ = catalogue.boj_catalogue_mount(0);
    try std.testing.expectEqual(@as(c_int, axioms.CAT_MOUNTED),
        catalogue.boj_catalogue_is_mounted(0));

    catalogue.boj_catalogue_deinit();
    // After deinit: count is 0, and all ops requiring init will fail.
    try std.testing.expectEqual(@as(usize, 0), catalogue.boj_catalogue_count());
    try std.testing.expectEqual(@as(c_int, axioms.CAT_ERR), registerReady("ghost"));
}

// ═══════════════════════════════════════════════════════════════════════════
// §C  Cartridge invoke ABI tests (via cartridge_shim.zig pub functions)
// ═══════════════════════════════════════════════════════════════════════════

test "C.1: writeResult — body fits, RC_SUCCESS, length updated" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = shim.writeResult(&buf, &len, "hello");
    try std.testing.expectEqual(@as(i32, axioms.RC_SUCCESS), rc);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..len]);
}

test "C.2: [BOUNDARY] writeResult — exact-fit buffer succeeds" {
    var buf: [5]u8 = undefined;
    var len: usize = buf.len;
    const rc = shim.writeResult(&buf, &len, "hello");
    try std.testing.expectEqual(@as(i32, axioms.RC_SUCCESS), rc);
    try std.testing.expectEqual(@as(usize, 5), len);
}

test "C.3: [BOUNDARY] writeResult — buffer too small, RC_BUFFER_TOO_SMALL, required length set" {
    var buf: [2]u8 = undefined;
    var len: usize = buf.len;
    const rc = shim.writeResult(&buf, &len, "hello");
    try std.testing.expectEqual(@as(i32, axioms.RC_BUFFER_TOO_SMALL), rc);
    // *in_out_len must be updated to the required size (body.len = 5).
    try std.testing.expectEqual(@as(usize, 5), len);
}

test "C.4: writeResult — empty body writes nothing, RC_SUCCESS" {
    var buf: [4]u8 = undefined;
    var len: usize = buf.len;
    const rc = shim.writeResult(&buf, &len, "");
    try std.testing.expectEqual(@as(i32, axioms.RC_SUCCESS), rc);
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "C.5: [BOUNDARY] writeResult — zero-capacity buffer, non-empty body, RC_BUFFER_TOO_SMALL" {
    var buf: [1]u8 = undefined;
    var len: usize = 0; // capacity=0
    const rc = shim.writeResult(&buf, &len, "x");
    try std.testing.expectEqual(@as(i32, axioms.RC_BUFFER_TOO_SMALL), rc);
    try std.testing.expectEqual(@as(usize, 1), len); // required = body.len
}

test "C.6: toolIs — exact match and non-match" {
    const name: [*:0]const u8 = "list-databases";
    try std.testing.expect(shim.toolIs(@ptrCast(name), "list-databases"));
    try std.testing.expect(!shim.toolIs(@ptrCast(name), "list-database"));
    try std.testing.expect(!shim.toolIs(@ptrCast(name), "list-databasess"));
    try std.testing.expect(!shim.toolIs(@ptrCast(name), ""));
}

test "C.7: invokeArgsNull — each null slot detected independently" {
    var buf: [4]u8 = undefined;
    var len: usize = 4;
    const name: [*:0]const u8 = "x";
    try std.testing.expect(!shim.invokeArgsNull(@ptrCast(name), &buf, &len));
    try std.testing.expect(shim.invokeArgsNull(null, &buf, &len));
    try std.testing.expect(shim.invokeArgsNull(@ptrCast(name), null, &len));
    try std.testing.expect(shim.invokeArgsNull(@ptrCast(name), &buf, null));
}

test "C.8: RC_BUFFER_TOO_SMALL hint enables two-phase caller pattern" {
    // Simulate the ADR-0006 two-phase call:
    //   Phase 1: call with capacity=0 to discover required size.
    //   Phase 2: allocate required size, call again — must succeed.
    var dummy: [0]u8 = .{};
    var cap: usize = 0;
    const body = "{\"result\":{\"rows\":42}}";

    const probe = shim.writeResult(&dummy, &cap, body);
    try std.testing.expectEqual(@as(i32, axioms.RC_BUFFER_TOO_SMALL), probe);
    try std.testing.expectEqual(@as(usize, body.len), cap); // hint is exact

    var real_buf: [64]u8 = undefined;
    var real_cap: usize = cap;
    const fill = shim.writeResult(&real_buf, &real_cap, body);
    try std.testing.expectEqual(@as(i32, axioms.RC_SUCCESS), fill);
    try std.testing.expectEqualSlices(u8, body, real_buf[0..real_cap]);
}

// ═══════════════════════════════════════════════════════════════════════════
// §D  Hash constant boundary tests
// ═══════════════════════════════════════════════════════════════════════════
//
// loader.zig's pub functions (hashToHex, verifyHash, etc.) are tested by the
// loader module's own test suite (`zig build loader`).  The module cannot be
// imported here due to a module-graph conflict (see §A.6 GAP).
//
// What we CAN verify here: the axiom constants themselves behave consistently
// with the hexadecimal encoding specification, without calling any loader code.

test "D.1: axioms.HASH_HEX_LEN is double axioms.HASH_LEN (hex-encoding contract)" {
    // This test is redundant with ax.3.1 (comptime), but makes the property
    // explicitly visible in the runtime test report as a named failing test.
    try std.testing.expectEqual(@as(usize, axioms.HASH_LEN * 2), axioms.HASH_HEX_LEN);
}

test "D.2: SHA-256 hex string fits in NAME_MAX field (catalogue storage axiom)" {
    // boj_catalogue_set_hash stores the hex string in [NAME_MAX]u8.
    // If HASH_HEX_LEN > NAME_MAX, the write would overflow.
    try std.testing.expect(axioms.HASH_HEX_LEN <= axioms.NAME_MAX);
}

test "D.3: WASM capacity bounded by catalogue capacity" {
    try std.testing.expect(axioms.MAX_WASM_CARTRIDGES <= axioms.MAX_CARTRIDGES);
}

test "D.4: LOADER_MATCH does not alias CAT_OK (convention mismatch trap)" {
    // boj_loader_verify() returns LOADER_MATCH (1) on success, NOT CAT_OK (0).
    // A caller checking `rc == 0` would misidentify a hash-mismatch as success.
    try std.testing.expect(axioms.LOADER_MATCH != axioms.CAT_OK);
}

// ═══════════════════════════════════════════════════════════════════════════
// §E  Safety boundary tests (via SafetyError enum and extern declarations)
// ═══════════════════════════════════════════════════════════════════════════
//
// The safety functions are `export fn` (not pub) in safety.zig.  They are
// declared extern here so the linker resolves them from the linked safety
// module object code.

extern fn boj_safety_check_shell_arg(ptr: [*]const u8, len: usize) c_int;
extern fn boj_safety_check_sql_value(ptr: [*]const u8, len: usize) c_int;
extern fn boj_safety_check_path(ptr: [*]const u8, len: usize) c_int;
extern fn boj_safety_check_url_scheme(ptr: [*]const u8, len: usize) c_int;
extern fn boj_safety_check_json_string(ptr: [*]const u8, len: usize) c_int;

test "E.1: shell arg — empty input returns SAFETY_EMPTY" {
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_EMPTY),
        boj_safety_check_shell_arg("", 0));
}

test "E.2: [BOUNDARY] shell arg — length exactly MAX_SHELL_ARG passes" {
    const long: [axioms.MAX_SHELL_ARG]u8 = .{'a'} ** axioms.MAX_SHELL_ARG;
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_shell_arg(&long, long.len));
}

test "E.3: [BOUNDARY] shell arg — length MAX_SHELL_ARG+1 returns SAFETY_TOO_LONG" {
    const toolong: [axioms.MAX_SHELL_ARG + 1]u8 = .{'a'} ** (axioms.MAX_SHELL_ARG + 1);
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_TOO_LONG),
        boj_safety_check_shell_arg(&toolong, toolong.len));
}

test "E.4: shell arg — allowlist characters all pass" {
    const allowed = "abcXYZ019-_./:@+=,~";
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_shell_arg(allowed, allowed.len));
}

test "E.5: shell arg — each shell metacharacter is rejected" {
    const dangerous = [_][]const u8{ ";", "|", "&", "$", "`", "(", ")", " ", "\"", "'" };
    for (dangerous) |ch| {
        const rc = boj_safety_check_shell_arg(ch.ptr, ch.len);
        try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SHELL_INJECTION), rc);
    }
}

test "E.6: [BOUNDARY] shell arg — double-hyphen (option injection) rejected" {
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SHELL_INJECTION),
        boj_safety_check_shell_arg("--evil", 6));
    // Single hyphen at start is allowed.
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_shell_arg("-", 1));
}

test "E.7: SQL value — SQL injection patterns all rejected" {
    const cases = [_][]const u8{
        "'; DROP TABLE--",  // comment + terminator + quote
        "1; DELETE FROM",   // statement terminator
        "/* comment */",    // block comment
        "val' OR '1'='1",  // string escape
        "val\\escaped",    // backslash escape
    };
    for (cases) |c| {
        const rc = boj_safety_check_sql_value(c.ptr, c.len);
        try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SQL_INJECTION), rc);
    }
}

test "E.8: SQL value — safe strings pass, empty passes" {
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_sql_value("hello world", 11));
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_sql_value("", 0));
}

test "E.9: path — traversal sequences rejected at any position" {
    const traversals = [_][]const u8{
        "../etc/passwd",
        "/safe/../escape",
        "../../secret",
    };
    for (traversals) |t| {
        try std.testing.expectEqual(@as(c_int, axioms.SAFETY_PATH_TRAVERSAL),
            boj_safety_check_path(t.ptr, t.len));
    }
}

test "E.10: path — safe paths pass" {
    const safe = [_][]const u8{
        "/usr/bin/git",
        "relative/path.txt",
        "/home/user/file",
    };
    for (safe) |s| {
        try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
            boj_safety_check_path(s.ptr, s.len));
    }
}

test "E.11: URL scheme — only http and https pass; dangerous schemes rejected" {
    // Safe.
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_url_scheme("https://example.com", 19));
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_url_scheme("http://x.com", 12));
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_url_scheme("/relative", 9));
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_url_scheme("", 0));

    // Dangerous.
    const bad = [_][]const u8{
        "javascript:alert(1)",
        "data:text/html,<x>",
        "file:///etc/passwd",
        "vbscript:msgbox",
        "ftp://x.com",
    };
    for (bad) |u| {
        try std.testing.expectEqual(@as(c_int, axioms.SAFETY_INVALID_URL),
            boj_safety_check_url_scheme(u.ptr, u.len));
    }
}

test "E.12: JSON string — control characters, backslash, quote all rejected" {
    // Control character (NUL).
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_JSON_UNSAFE),
        boj_safety_check_json_string("\x00", 1));
    // Backslash.
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_JSON_UNSAFE),
        boj_safety_check_json_string("a\\b", 3));
    // Double quote.
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_JSON_UNSAFE),
        boj_safety_check_json_string("a\"b", 3));
    // Clean string.
    try std.testing.expectEqual(@as(c_int, axioms.SAFETY_SAFE),
        boj_safety_check_json_string("hello world", 11));
}

// ═══════════════════════════════════════════════════════════════════════════
// §F  Thread-safety spot check
// ═══════════════════════════════════════════════════════════════════════════
//
// Zig's Thread.Mutex guarantees mutual exclusion; the formal proof that the
// mutex is held on EVERY C-ABI entry is provided by the comptime exhaustive
// audit in seams.zig (Seam 8) and the code review in docs/zig-ffi-verification.adoc.
// The test below provides operational evidence that concurrent registration
// does not corrupt the count.
//
// [GAP] This test is a safety net, not a full data-race proof.  A formal
// proof of race-freedom requires a happens-before analysis tool (e.g., tsan
// or a model checker) which is not yet wired into this project's CI.

const THREAD_COUNT = 8;
const REGISTRATIONS_PER_THREAD = 4; // 8 * 4 = 32, well within MAX_CARTRIDGES

fn threadRegister(id: usize) void {
    var i: usize = 0;
    while (i < REGISTRATIONS_PER_THREAD) : (i += 1) {
        var buf: [16]u8 = undefined;
        const n = std.fmt.bufPrint(&buf, "t{d}c{d}", .{ id, i }) catch return;
        _ = catalogue.boj_catalogue_register(
            n.ptr, n.len,
            "1.0".ptr, 3,
            axioms.STATUS_READY, axioms.TIER_TERANGA, axioms.DOMAIN_CLOUD,
        );
    }
}

test "F.1: concurrent registration is race-free (mutex spot check)" {
    catalogue.boj_catalogue_deinit();
    _ = catalogue.boj_catalogue_init();
    defer catalogue.boj_catalogue_deinit();

    var threads: [THREAD_COUNT]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, threadRegister, .{i});
    }
    for (&threads) |*t| t.join();

    const expected = THREAD_COUNT * REGISTRATIONS_PER_THREAD;
    try std.testing.expectEqual(@as(usize, expected), catalogue.boj_catalogue_count());
}
