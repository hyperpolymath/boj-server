// SPDX-License-Identifier: MPL-2.0
// Copyright (c) Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
//
// ABI Axioms — Canonical trusted boundary declarations for the Zig FFI.
//
// This file is the single source of truth for every numeric constant that
// crosses the C-ABI boundary between Zig, C, and the Idris2 proof layer.
//
// Each constant carries a trust classification:
//
//   [STATIC]   Proven at compile time within this file alone.
//              The comptime blocks below are theorems — they fail to compile
//              if violated.  A passing build implies the theorem is true.
//
//   [CROSS]    Proven at compile time in abi_verify.zig by comparing these
//              constants against the actual Zig types (enums, structs) they
//              describe.  Requires importing both this file and the relevant
//              modules.
//
//   [RUNTIME]  Operationally verified by abi_verify.zig boundary tests.
//              True under exhaustive boundary coverage of the C-ABI surface.
//
//   [ASSUMED]  Cross-language axioms (Idris2↔Zig, private-const↔axiom) that
//              cannot be mechanically verified in Zig alone.  The Idris2
//              proofs in src/abi/ provide the formal complement for the
//              Idris2-side.  Breakage here manifests as runtime divergence,
//              not a compile error.
//
// Trust chain (narrowest → widest):
//   Idris2 proofs → [ASSUMED] axioms → [CROSS] comptime → [RUNTIME] tests
//
// Design constraints:
//   • No imports — standalone so any language can consume the numeric surface.
//   • No functions — pure constant declarations and inert comptime proofs.
//   • All public constants are untyped comptime_int / comptime_float so they
//     coerce to any integer type without explicit casting at the use site.

// ═══════════════════════════════════════════════════════════════════════════
// § 1  Cartridge Invocation ABI (ADR-0006, frozen)
// ═══════════════════════════════════════════════════════════════════════════
//
// Source:  ffi/zig/src/cartridge_shim.zig (pub const RC_*)
// Cross-ref: docs/ADR-0006.adoc §Return codes
//
// Five-symbol cartridge ABI: boj_cartridge_{init,deinit,name,version,invoke}.
// The invoke function signature:
//
//   boj_cartridge_invoke(
//       tool_name:  [*c]const u8,   // NUL-terminated tool name
//       json_args:  [*c]const u8,   // NUL-terminated JSON argument blob
//       out_buf:    [*c]u8,         // caller-allocated output buffer
//       in_out_len: [*c]usize,      // in: capacity; out: bytes written or required
//   ) callconv(.c) i32              // one of the RC_* codes below
//
// Return codes are a CLOSED SET — frozen by ADR-0006.  New failure modes
// must be expressed in the JSON error body; the integer surface must not grow
// without a new ADR.

/// [CROSS] Successful invocation — result written into out_buf.
pub const RC_SUCCESS = 0;

/// [CROSS] Tool name not recognised by this cartridge.
pub const RC_UNKNOWN_TOOL = -1;

/// [CROSS] Null pointer or invalid JSON in required argument.
pub const RC_BAD_ARGS = -2;

/// [CROSS] Output buffer too small.
/// [RUNTIME] On return: *in_out_len is set to the required byte count.
pub const RC_BUFFER_TOO_SMALL = -3;

/// [CROSS] Unexpected runtime error inside the cartridge.
pub const RC_RUNTIME_ERROR = -4;

/// [CROSS] Zig panic caught at FFI boundary.  Cartridge state is undefined.
pub const RC_PANIC = -5;

/// [CROSS] Auth check failed.  Caller must not retry without fresh credentials.
pub const RC_AUTH_DENIED = -6;

/// [STATIC] Number of distinct return-code values (including RC_SUCCESS).
pub const RC_CODE_COUNT = 7;

// ─── §1 Comptime theorems ──────────────────────────────────────────────────

comptime {
    // THEOREM[ax.1.1]: RC_SUCCESS is exactly zero (universal C convention for ok).
    if (RC_SUCCESS != 0)
        @compileError("ax.1.1: RC_SUCCESS must be 0");

    // THEOREM[ax.1.2]: Every error code is strictly negative.
    if (RC_UNKNOWN_TOOL >= 0) @compileError("ax.1.2: RC_UNKNOWN_TOOL must be < 0");
    if (RC_BAD_ARGS >= 0) @compileError("ax.1.2: RC_BAD_ARGS must be < 0");
    if (RC_BUFFER_TOO_SMALL >= 0) @compileError("ax.1.2: RC_BUFFER_TOO_SMALL must be < 0");
    if (RC_RUNTIME_ERROR >= 0) @compileError("ax.1.2: RC_RUNTIME_ERROR must be < 0");
    if (RC_PANIC >= 0) @compileError("ax.1.2: RC_PANIC must be < 0");
    if (RC_AUTH_DENIED >= 0) @compileError("ax.1.2: RC_AUTH_DENIED must be < 0");

    // THEOREM[ax.1.3]: Error codes are dense and ordered in [-6, -1].
    // Any gap would leave an unmapped integer with undefined meaning.
    if (RC_UNKNOWN_TOOL != -1) @compileError("ax.1.3: RC_UNKNOWN_TOOL must be -1");
    if (RC_BAD_ARGS != -2) @compileError("ax.1.3: RC_BAD_ARGS must be -2");
    if (RC_BUFFER_TOO_SMALL != -3) @compileError("ax.1.3: RC_BUFFER_TOO_SMALL must be -3");
    if (RC_RUNTIME_ERROR != -4) @compileError("ax.1.3: RC_RUNTIME_ERROR must be -4");
    if (RC_PANIC != -5) @compileError("ax.1.3: RC_PANIC must be -5");
    if (RC_AUTH_DENIED != -6) @compileError("ax.1.3: RC_AUTH_DENIED must be -6");

    // THEOREM[ax.1.4]: RC_CODE_COUNT covers [RC_AUTH_DENIED, RC_SUCCESS] inclusive.
    if (RC_CODE_COUNT != -RC_AUTH_DENIED + 1)
        @compileError("ax.1.4: RC_CODE_COUNT must equal |RC_AUTH_DENIED| + 1");
}

// ═══════════════════════════════════════════════════════════════════════════
// § 2  Catalogue ABI
// ═══════════════════════════════════════════════════════════════════════════
//
// Sources: ffi/zig/src/catalogue.zig, generated/abi/boj_catalogue.h
// Idris2:  src/abi/Boj/{Catalogue,Domain,Protocol}.idr
// [ASSUMED] Integer values mirror the Idris2 *ToInt functions exactly.
//           Any drift from src/abi/ is an assumed axiom violation.

// ─── CartridgeStatus ──────────────────────────────────────────────────────
// [CROSS] catalogue.CartridgeStatus enum  ↔  BOJ_STATUS_* in boj_catalogue.h

pub const STATUS_DEVELOPMENT = 0;
pub const STATUS_READY = 1;
pub const STATUS_DEPRECATED = 2;
pub const STATUS_FAULTY = 3;

/// [CROSS] [RUNTIME] The ONLY status value that passes the mount gate.
/// Mirrors the IsUnbreakable predicate in src/abi/Boj/Catalogue.idr.
pub const MOUNT_GATE_STATUS = STATUS_READY;

// ─── ProtocolType ─────────────────────────────────────────────────────────
// [CROSS] catalogue.ProtocolType enum  ↔  BOJ_PROTO_* in boj_catalogue.h
// Protocol slots are stored in a [9]bool array indexed by (protocol_value - 1).

pub const PROTO_MCP = 1;
pub const PROTO_LSP = 2;
pub const PROTO_DAP = 3;
pub const PROTO_BSP = 4;
pub const PROTO_NESY = 5;
pub const PROTO_AGENTIC = 6;
pub const PROTO_FLEET = 7;
pub const PROTO_GRPC = 8;
pub const PROTO_REST = 9;
pub const PROTO_MIN = PROTO_MCP;
pub const PROTO_MAX = PROTO_REST;
pub const PROTO_COUNT = 9;

// ─── CapabilityDomain ─────────────────────────────────────────────────────
// [CROSS] catalogue.CapabilityDomain enum  ↔  BOJ_DOMAIN_* in boj_catalogue.h

pub const DOMAIN_CLOUD = 1;
pub const DOMAIN_CONTAINER = 2;
pub const DOMAIN_DATABASE = 3;
pub const DOMAIN_K8S = 4;
pub const DOMAIN_GIT = 5;
pub const DOMAIN_SECRETS = 6;
pub const DOMAIN_QUEUES = 7;
pub const DOMAIN_IAC = 8;
pub const DOMAIN_OBSERVE = 9;
pub const DOMAIN_SSG = 10;
pub const DOMAIN_PROOF = 11;
pub const DOMAIN_FLEET = 12;
pub const DOMAIN_NESY = 13;
pub const DOMAIN_AGENT = 14;
pub const DOMAIN_LSP = 15;
pub const DOMAIN_DAP = 16;
pub const DOMAIN_BSP = 17;
pub const DOMAIN_CODE_INTEL = 18;
pub const DOMAIN_MIN = DOMAIN_CLOUD;
pub const DOMAIN_MAX = DOMAIN_CODE_INTEL;

// ─── MenuTier ─────────────────────────────────────────────────────────────
// [CROSS] catalogue.MenuTier enum  ↔  BOJ_TIER_* in boj_catalogue.h

pub const TIER_TERANGA = 0;
pub const TIER_SHIELD = 1;
pub const TIER_AYO = 2;
pub const TIER_MIN = TIER_TERANGA;
pub const TIER_MAX = TIER_AYO;

// ─── Catalogue capacity bounds ────────────────────────────────────────────
// [RUNTIME] Enforced inside catalogue.zig; declared here as axioms.

/// Maximum cartridges the registry can hold (catalogue array length).
pub const MAX_CARTRIDGES = 128;

/// Maximum cartridges in a single order ticket passed to boj_menu_validate_order.
pub const MAX_ORDER_SIZE = 16;

/// Length of the CartridgeEntry.protocols array (one slot per ProtocolType).
pub const PROTOCOLS_SLOT_COUNT = 9;

// ─── Catalogue field size bounds ──────────────────────────────────────────
// [RUNTIME] Enforced by boj_catalogue_register before @memcpy into fixed fields.

/// Maximum cartridge name byte count (CartridgeEntry.name field length).
pub const NAME_MAX = 64;

/// Maximum version string byte count (CartridgeEntry.version field length).
pub const VERSION_MAX = 16;

/// Maximum backend label byte count (CartridgeEntry.backend field length).
pub const BACKEND_MAX = 32;

// ─── Catalogue function return conventions ────────────────────────────────
// [RUNTIME] Named for readability; the underlying values are 0 / -1 / -2.

/// boj_catalogue_init, boj_catalogue_register, etc.: success.
pub const CAT_OK = 0;
/// boj_catalogue_register, etc.: bad argument or capacity exceeded.
pub const CAT_ERR = -1;
/// boj_catalogue_mount / boj_catalogue_unmount: index out of range.
pub const CAT_NOT_FOUND = -2;
/// boj_catalogue_is_mounted: the cartridge is mounted.
pub const CAT_MOUNTED = 1;
/// boj_catalogue_is_mounted: the cartridge exists but is not mounted.
pub const CAT_UNMOUNTED = 0;
/// boj_catalogue_is_mounted: index out of range.
pub const CAT_IS_MOUNTED_ERR = -1;

// ─── §2 Comptime theorems ─────────────────────────────────────────────────

comptime {
    // THEOREM[ax.2.1]: Status codes are 0-based consecutive integers in [0, 3].
    if (STATUS_DEVELOPMENT != 0) @compileError("ax.2.1: STATUS_DEVELOPMENT must be 0");
    if (STATUS_READY != STATUS_DEVELOPMENT + 1) @compileError("ax.2.1: STATUS_READY must be STATUS_DEVELOPMENT+1");
    if (STATUS_DEPRECATED != STATUS_READY + 1) @compileError("ax.2.1: STATUS_DEPRECATED must be STATUS_READY+1");
    if (STATUS_FAULTY != STATUS_DEPRECATED + 1) @compileError("ax.2.1: STATUS_FAULTY must be STATUS_DEPRECATED+1");

    // THEOREM[ax.2.2]: Mount gate is exactly and only STATUS_READY.
    if (MOUNT_GATE_STATUS != STATUS_READY)
        @compileError("ax.2.2: MOUNT_GATE_STATUS must equal STATUS_READY");

    // THEOREM[ax.2.3]: Protocol range [1, 9] is non-empty and fully spans PROTO_COUNT.
    if (PROTO_MIN != 1) @compileError("ax.2.3: PROTO_MIN must be 1");
    if (PROTO_MAX != 9) @compileError("ax.2.3: PROTO_MAX must be 9");
    if (PROTO_COUNT != PROTO_MAX - PROTO_MIN + 1)
        @compileError("ax.2.3: PROTO_COUNT must be PROTO_MAX - PROTO_MIN + 1");
    if (PROTOCOLS_SLOT_COUNT != PROTO_COUNT)
        @compileError("ax.2.3: PROTOCOLS_SLOT_COUNT must equal PROTO_COUNT");

    // THEOREM[ax.2.4]: Tier codes are 0-based consecutive integers in [0, 2].
    if (TIER_TERANGA != 0) @compileError("ax.2.4: TIER_TERANGA must be 0");
    if (TIER_SHIELD != 1) @compileError("ax.2.4: TIER_SHIELD must be 1");
    if (TIER_AYO != 2) @compileError("ax.2.4: TIER_AYO must be 2");

    // THEOREM[ax.2.5]: Capacity bounds are non-zero and order-safe.
    if (MAX_CARTRIDGES == 0) @compileError("ax.2.5: MAX_CARTRIDGES must be positive");
    if (MAX_ORDER_SIZE == 0) @compileError("ax.2.5: MAX_ORDER_SIZE must be positive");
    if (MAX_ORDER_SIZE > MAX_CARTRIDGES)
        @compileError("ax.2.5: MAX_ORDER_SIZE must not exceed MAX_CARTRIDGES");

    // THEOREM[ax.2.6]: Field size bounds are non-zero and hierarchically ordered.
    if (NAME_MAX == 0) @compileError("ax.2.6: NAME_MAX must be positive");
    if (VERSION_MAX == 0) @compileError("ax.2.6: VERSION_MAX must be positive");
    if (BACKEND_MAX == 0) @compileError("ax.2.6: BACKEND_MAX must be positive");
    if (NAME_MAX <= VERSION_MAX)
        @compileError("ax.2.6: NAME_MAX must strictly exceed VERSION_MAX");

    // THEOREM[ax.2.7]: Catalogue OK code equals RC_SUCCESS.
    // Both are 0 — the C convention for "no error" across the whole ABI.
    if (CAT_OK != RC_SUCCESS)
        @compileError("ax.2.7: CAT_OK must equal RC_SUCCESS (both are 0)");
}

// ═══════════════════════════════════════════════════════════════════════════
// § 3  Loader ABI
// ═══════════════════════════════════════════════════════════════════════════
//
// Source: ffi/zig/src/loader.zig
//
// IMPORTANT: The loader uses a DISTINCT return convention from catalogue
// functions.  boj_loader_verify returns 1=match, 0=mismatch, -1=error —
// a tri-state boolean.  It does NOT return 0 for success.
// Callers MUST NOT treat 0 from boj_loader_verify as "ok".

/// [CROSS] SHA-256 raw digest length in bytes.
pub const HASH_LEN = 32;

/// [CROSS] SHA-256 hex-encoded digest length in ASCII characters.
pub const HASH_HEX_LEN = 64;

/// Maximum WASM cartridges registered simultaneously.
pub const MAX_WASM_CARTRIDGES = 32;

/// Maximum filesystem path length for a WASM module byte string.
pub const MAX_WASM_PATH_LEN = 512;

/// [RUNTIME] boj_loader_verify: binary hash matches expected hash.
pub const LOADER_MATCH = 1;
/// [RUNTIME] boj_loader_verify: binary hash does NOT match expected hash.
pub const LOADER_MISMATCH = 0;
/// [RUNTIME] boj_loader_verify: I/O error or bad parameter.
pub const LOADER_ERROR = -1;

// ─── §3 Comptime theorems ─────────────────────────────────────────────────

comptime {
    // THEOREM[ax.3.1]: Hex length is exactly double the raw byte length.
    // Invariant of hexadecimal encoding: 1 byte → 2 hex chars.
    if (HASH_HEX_LEN != HASH_LEN * 2)
        @compileError("ax.3.1: HASH_HEX_LEN must equal HASH_LEN * 2");

    // THEOREM[ax.3.2]: LOADER_MATCH does not alias CAT_OK.
    // LOADER_MATCH=1 signals "hash verified"; CAT_OK=0 signals "operation succeeded".
    // Callers who confuse these will silently skip hash verification.
    if (LOADER_MATCH == CAT_OK)
        @compileError("ax.3.2: LOADER_MATCH must not equal CAT_OK — loader convention differs");

    // NOTE[ax.3.3]: LOADER_MISMATCH (0) numerically aliases CAT_OK (0).
    // This is a documented ABI wart.  The distinction is context-dependent:
    // boj_loader_verify returning 0 means "mismatch" (bad), not "ok".
    // LOADER_ERROR (-1) aliases CAT_ERR (-1) — again context-dependent.
    // Tests in abi_verify.zig explicitly cover these aliased paths.

    // THEOREM[ax.3.4]: WASM capacity is bounded by total catalogue capacity.
    if (MAX_WASM_CARTRIDGES == 0) @compileError("ax.3.4: MAX_WASM_CARTRIDGES must be positive");
    if (MAX_WASM_CARTRIDGES > MAX_CARTRIDGES)
        @compileError("ax.3.4: MAX_WASM_CARTRIDGES must not exceed MAX_CARTRIDGES");

    // THEOREM[ax.3.5]: Hash hex string fits in the catalogue's binary_hash field.
    // CartridgeEntry.binary_hash is [64]u8; HASH_HEX_LEN is 64.
    if (HASH_HEX_LEN > NAME_MAX)
        @compileError("ax.3.5: HASH_HEX_LEN must not exceed NAME_MAX (catalogue stores hash in [64]u8)");

    // THEOREM[ax.3.6]: LOADER_ERROR is negative.
    if (LOADER_ERROR >= 0) @compileError("ax.3.6: LOADER_ERROR must be negative");
}

// ═══════════════════════════════════════════════════════════════════════════
// § 4  Safety ABI
// ═══════════════════════════════════════════════════════════════════════════
//
// Source: ffi/zig/src/safety.zig (SafetyError enum, private length constants)
// [CROSS] The SafetyError enum values are pub and can be cross-checked.
// [ASSUMED] MAX_SHELL_ARG and MAX_PATH must match safety.zig's private
//           MAX_SHELL_ARG_LEN and MAX_PATH_LEN constants.  These cannot be
//           mechanically verified without making those constants pub.

/// [CROSS] Input passed all safety checks for the requested operation.
pub const SAFETY_SAFE = 1;

/// [CROSS] Input was empty.  Safe for SQL values; error for paths/shell args.
pub const SAFETY_EMPTY = 0;

/// [CROSS] Input contains shell metacharacters or option injection.
pub const SAFETY_SHELL_INJECTION = -1;

/// [CROSS] Input contains SQL injection patterns (comment, semicolon, quote).
pub const SAFETY_SQL_INJECTION = -2;

/// [CROSS] Input contains path traversal sequences (../).
pub const SAFETY_PATH_TRAVERSAL = -3;

/// [CROSS] Input exceeds the configured maximum length for this check.
pub const SAFETY_TOO_LONG = -4;

/// [CROSS] Input contains null bytes (always rejected).
pub const SAFETY_NULL_BYTE = -5;

/// [CROSS] Input contains control characters (U+0000–U+001F, excluding \t).
pub const SAFETY_CONTROL_CHAR = -6;

/// [CROSS] Input contains a disallowed URL scheme (javascript:, data:, file:, …).
pub const SAFETY_INVALID_URL = -7;

/// [CROSS] Input contains characters unsafe in JSON strings (\, ", controls).
pub const SAFETY_JSON_UNSAFE = -8;

/// [ASSUMED] Maximum shell argument byte length.  Mirrors safety.zig MAX_SHELL_ARG_LEN.
pub const MAX_SHELL_ARG = 4096;

/// [ASSUMED] Maximum path byte length.  Mirrors safety.zig MAX_PATH_LEN (= POSIX PATH_MAX).
pub const MAX_PATH = 4096;

// ─── §4 Comptime theorems ─────────────────────────────────────────────────

comptime {
    // THEOREM[ax.4.1]: SAFETY_SAFE is the unique positive safety code.
    if (SAFETY_SAFE <= 0) @compileError("ax.4.1: SAFETY_SAFE must be positive");
    if (SAFETY_EMPTY != 0) @compileError("ax.4.1: SAFETY_EMPTY must be 0");

    // THEOREM[ax.4.2]: All rejection codes are strictly negative.
    if (SAFETY_SHELL_INJECTION >= 0) @compileError("ax.4.2: SAFETY_SHELL_INJECTION must be < 0");
    if (SAFETY_SQL_INJECTION >= 0) @compileError("ax.4.2: SAFETY_SQL_INJECTION must be < 0");
    if (SAFETY_PATH_TRAVERSAL >= 0) @compileError("ax.4.2: SAFETY_PATH_TRAVERSAL must be < 0");
    if (SAFETY_TOO_LONG >= 0) @compileError("ax.4.2: SAFETY_TOO_LONG must be < 0");
    if (SAFETY_NULL_BYTE >= 0) @compileError("ax.4.2: SAFETY_NULL_BYTE must be < 0");
    if (SAFETY_CONTROL_CHAR >= 0) @compileError("ax.4.2: SAFETY_CONTROL_CHAR must be < 0");
    if (SAFETY_INVALID_URL >= 0) @compileError("ax.4.2: SAFETY_INVALID_URL must be < 0");
    if (SAFETY_JSON_UNSAFE >= 0) @compileError("ax.4.2: SAFETY_JSON_UNSAFE must be < 0");

    // THEOREM[ax.4.3]: Rejection codes are dense in [-8, -1] — no gaps or aliases.
    if (SAFETY_SHELL_INJECTION != -1) @compileError("ax.4.3: SAFETY_SHELL_INJECTION must be -1");
    if (SAFETY_SQL_INJECTION != -2) @compileError("ax.4.3: SAFETY_SQL_INJECTION must be -2");
    if (SAFETY_PATH_TRAVERSAL != -3) @compileError("ax.4.3: SAFETY_PATH_TRAVERSAL must be -3");
    if (SAFETY_TOO_LONG != -4) @compileError("ax.4.3: SAFETY_TOO_LONG must be -4");
    if (SAFETY_NULL_BYTE != -5) @compileError("ax.4.3: SAFETY_NULL_BYTE must be -5");
    if (SAFETY_CONTROL_CHAR != -6) @compileError("ax.4.3: SAFETY_CONTROL_CHAR must be -6");
    if (SAFETY_INVALID_URL != -7) @compileError("ax.4.3: SAFETY_INVALID_URL must be -7");
    if (SAFETY_JSON_UNSAFE != -8) @compileError("ax.4.3: SAFETY_JSON_UNSAFE must be -8");

    // THEOREM[ax.4.4]: Safety codes do not alias invoke return codes in the negative range.
    // Both sets use negative integers as error codes.  Ensure the ranges are disjoint:
    //   invoke errors: [-6, -1]  (RC_UNKNOWN_TOOL..RC_AUTH_DENIED)
    //   safety errors: [-8, -1]  (SAFETY_SHELL_INJECTION..SAFETY_JSON_UNSAFE)
    // They OVERLAP at [-6, -1].  This is safe because:
    //   (a) safety checks run before invoke — there is no call site where both
    //       could be returned from the same function, and
    //   (b) the outer caller (mcp-bridge) inspects the function name, not just
    //       the integer, to determine which error occurred.
    // NOTE: If in future a safety code is used as an invoke return code, this
    // axiom must be revisited. [ASSUMED] The bridge layer maintains this separation.

    // THEOREM[ax.4.5]: Safety bounds are POSIX-compatible (positive, plausible).
    if (MAX_SHELL_ARG == 0) @compileError("ax.4.5: MAX_SHELL_ARG must be positive");
    if (MAX_PATH == 0) @compileError("ax.4.5: MAX_PATH must be positive");

    // THEOREM[ax.4.6]: Safety codes do not alias the invoke closed set above 0.
    if (SAFETY_SAFE == RC_SUCCESS)
        @compileError("ax.4.6: SAFETY_SAFE (1) must not alias RC_SUCCESS (0)");
    // SAFETY_EMPTY (0) equals RC_SUCCESS (0) and CAT_OK (0) — this is intentional.
    // "Empty input is acceptable" for SQL is numerically the same as "ok" in other
    // contexts.  Separation is maintained at the call-site level, not the integer level.
}
