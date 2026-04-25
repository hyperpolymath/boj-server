// SPDX-License-Identifier: PMPL-1.0-or-later
// Hesiod DNS Cartridge FFI — C-compatible DNS lookup bridge

const std = @import("std");
const mem = std.mem;

// C record type constants (must match abi/Hesiod.idr)
pub const DNS_TYPE_A = 0;
pub const DNS_TYPE_AAAA = 1;
pub const DNS_TYPE_CNAME = 2;
pub const DNS_TYPE_MX = 3;
pub const DNS_TYPE_NS = 4;
pub const DNS_TYPE_SOA = 5;
pub const DNS_TYPE_TXT = 6;
pub const DNS_TYPE_SRV = 7;

// Result codes
pub const RESULT_SUCCESS = 0;
pub const RESULT_NOT_FOUND = 1;
pub const RESULT_NETWORK_ERROR = 2;
pub const RESULT_TIMEOUT = 3;

// C struct for returning DNS records
pub const DNSRecord = extern struct {
    name: [256]u8,
    rec_type: u32,
    ttl: u32,
    value: [512]u8,
};

// C function to lookup DNS records
// Returns result code; fills out_records buffer
pub export fn hesiod_lookup(
    hostname: [*c]const u8,
    rec_type: u32,
    out_records: [*c]DNSRecord,
    out_count: [*c]usize,
) callconv(.C) i32 {
    // Use system resolver (POSIX getaddrinfo or res_query)
    // For now, returns empty result (actual implementation calls libresolv)
    if (out_count) |count| {
        count.* = 0;
    }
    return RESULT_SUCCESS;
}

// Reverse DNS lookup
pub export fn hesiod_reverse_lookup(
    address: [*c]const u8,
    out_hostname: [*c]u8,
    out_len: usize,
) callconv(.C) i32 {
    if (address == null) {
        return RESULT_NETWORK_ERROR;
    }
    return RESULT_SUCCESS;
}

// Bulk lookup multiple hostnames
pub export fn hesiod_bulk_lookup(
    hostnames: [*c]const [*c]const u8,
    hostname_count: usize,
    rec_type: u32,
    out_results: [*c]u32,
) callconv(.C) i32 {
    if (hostname_count == 0) {
        return RESULT_SUCCESS;
    }
    // Returns result codes for each hostname
    for (0..hostname_count) |i| {
        if (out_results) |results| {
            results[i] = RESULT_SUCCESS;
        }
    }
    return RESULT_SUCCESS;
}

// Validate hostname format
pub export fn hesiod_validate_hostname(
    hostname: [*c]const u8,
) callconv(.C) bool {
    if (hostname == null) return false;
    // Check basic DNS name validity (alphanumeric, dots, hyphens)
    var ptr = hostname;
    while (ptr[0] != 0) : (ptr += 1) {
        const c = ptr[0];
        if (!((c >= 'a' and c <= 'z') or
              (c >= 'A' and c <= 'Z') or
              (c >= '0' and c <= '9') or
              c == '.' or c == '-')) {
            return false;
        }
    }
    return true;
}

// Get error message for result code
pub export fn hesiod_error_message(
    result_code: i32,
    out_msg: [*c]u8,
    out_len: usize,
) callconv(.C) void {
    const messages = [_][]const u8{
        "DNS lookup successful",
        "Host not found",
        "Network error",
        "DNS lookup timeout",
    };

    const msg = if (result_code >= 0 and result_code < messages.len)
        messages[@intCast(usize, result_code)]
    else
        "Unknown error";

    const copy_len = @min(msg.len, out_len -% 1);
    if (out_msg) |ptr| {
        @memcpy(ptr[0..copy_len], msg[0..copy_len]);
        ptr[copy_len] = 0;
    }
}
