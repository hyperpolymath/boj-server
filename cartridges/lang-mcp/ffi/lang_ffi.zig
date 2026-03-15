// SPDX-License-Identifier: PMPL-1.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Lang-MCP Cartridge — Zig FFI bridge for nextgen-languages operations.
//
// Manages language runtime sessions for the hyperpolymath nextgen-languages
// family: Eclexia, AffineScript, BetLang, Ephapax, MyLang, WokeLang,
// Anvomidav, Phronesis, Error-lang, Julia-the-Viper, Me-dialect, Oblibeny.
//
// Each language session tracks: state machine (idle → compiling → checked → error),
// the language identity, and a URL endpoint for the language's compile/eval service.

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════
// Types
// ═══════════════════════════════════════════════════════════════════════

/// Language session state machine.
pub const LangState = enum(c_int) {
    idle = 0,
    compiling = 1,
    checked = 2,
    evaluating = 3,
    err = 4,
};

/// Supported nextgen-languages. Enum values are stable ABI identifiers.
pub const Language = enum(c_int) {
    eclexia = 1,
    affinescript = 2,
    betlang = 3,
    ephapax = 4,
    mylang = 5,
    wokelang = 6,
    anvomidav = 7,
    phronesis = 8,
    error_lang = 9,
    julia_the_viper = 10,
    me_dialect = 11,
    oblibeny = 12,
    custom = 99,
};

// ═══════════════════════════════════════════════════════════════════════
// Session State Machine
// ═══════════════════════════════════════════════════════════════════════

const MAX_SESSIONS: usize = 8;
const URL_BUF_SIZE: usize = 512;
const NAME_BUF_SIZE: usize = 64;

const LangSession = struct {
    active: bool,
    state: LangState,
    language: Language,
    url_buf: [URL_BUF_SIZE]u8,
    url_len: usize,
    name_buf: [NAME_BUF_SIZE]u8,
    name_len: usize,
};

var sessions: [MAX_SESSIONS]LangSession = [_]LangSession{.{
    .active = false,
    .state = .idle,
    .language = .custom,
    .url_buf = [_]u8{0} ** URL_BUF_SIZE,
    .url_len = 0,
    .name_buf = [_]u8{0} ** NAME_BUF_SIZE,
    .name_len = 0,
}} ** MAX_SESSIONS;

var mutex: std.Thread.Mutex = .{};

/// Validate a state transition.
fn isValidTransition(from: LangState, to: LangState) bool {
    return switch (from) {
        .idle => to == .compiling or to == .evaluating,
        .compiling => to == .checked or to == .err,
        .checked => to == .idle or to == .evaluating,
        .evaluating => to == .idle or to == .err,
        .err => to == .idle,
    };
}

/// Start a language session. Returns session index or -1.
pub export fn lang_session_start(lang_id: c_int, name_ptr: [*]const u8, name_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (name_len == 0 or name_len >= NAME_BUF_SIZE) return -2;

    for (&sessions, 0..) |*sess, i| {
        if (!sess.active) {
            sess.active = true;
            sess.state = .idle;
            sess.language = @enumFromInt(lang_id);
            sess.url_len = 0;
            @memcpy(sess.name_buf[0..name_len], name_ptr[0..name_len]);
            sess.name_len = name_len;
            return @intCast(i);
        }
    }
    return -1; // No sessions available
}

/// Set the language service URL for a session (for remote compilation/eval).
pub export fn lang_session_set_url(sess_idx: c_int, url_ptr: [*]const u8, url_len: usize) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (sess_idx < 0 or sess_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(sess_idx);
    if (!sessions[idx].active) return -1;
    if (url_len == 0 or url_len >= URL_BUF_SIZE) return -6;

    @memcpy(sessions[idx].url_buf[0..url_len], url_ptr[0..url_len]);
    sessions[idx].url_len = url_len;
    return 0;
}

/// End a language session.
pub export fn lang_session_end(sess_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (sess_idx < 0 or sess_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(sess_idx);
    if (!sessions[idx].active) return -1;

    sessions[idx].active = false;
    sessions[idx].state = .idle;
    sessions[idx].url_len = 0;
    sessions[idx].name_len = 0;
    return 0;
}

/// Get the state of a session.
pub export fn lang_session_state(sess_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (sess_idx < 0 or sess_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(sess_idx);
    if (!sessions[idx].active) return @intFromEnum(LangState.idle);
    return @intFromEnum(sessions[idx].state);
}

/// Get the language ID of a session.
pub export fn lang_session_language(sess_idx: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();

    if (sess_idx < 0 or sess_idx >= MAX_SESSIONS) return -1;
    const idx: usize = @intCast(sess_idx);
    if (!sessions[idx].active) return -1;
    return @intFromEnum(sessions[idx].language);
}

/// Type-check source code via the language service.
/// POSTs to {url}/typecheck with the source as JSON body.
pub export fn lang_typecheck(sess_idx: c_int, src_ptr: [*]const u8, src_len: usize, out_ptr: [*]u8, out_len: usize) callconv(.c) i32 {
    var endpoint_buf: [600]u8 = undefined;
    var endpoint_total: usize = 0;
    var src_buf: [16384]u8 = undefined;
    var safe_src_len: usize = 0;

    {
        mutex.lock();
        defer mutex.unlock();

        if (sess_idx < 0 or sess_idx >= MAX_SESSIONS) return -1;
        const idx: usize = @intCast(sess_idx);
        if (!sessions[idx].active) return -1;
        if (sessions[idx].state != .idle and sessions[idx].state != .checked) return -2;
        if (sessions[idx].url_len == 0) return -6;

        const url_slice = sessions[idx].url_buf[0..sessions[idx].url_len];
        const suffix = "/typecheck";
        if (url_slice.len + suffix.len >= endpoint_buf.len) return -6;
        @memcpy(endpoint_buf[0..url_slice.len], url_slice);
        @memcpy(endpoint_buf[url_slice.len..][0..suffix.len], suffix);
        endpoint_total = url_slice.len + suffix.len;
        endpoint_buf[endpoint_total] = 0;

        safe_src_len = @min(src_len, src_buf.len - 1);
        @memcpy(src_buf[0..safe_src_len], src_ptr[0..safe_src_len]);
        src_buf[safe_src_len] = 0;

        sessions[idx].state = .compiling;
    }

    const child_result = runCurlPost(
        endpoint_buf[0..endpoint_total :0],
        src_buf[0..safe_src_len :0],
    );

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = @intCast(sess_idx);
    if (!sessions[idx].active) return -1;

    if (child_result) |result| {
        defer std.heap.page_allocator.free(result);
        const written = result.len;
        if (written > out_len) {
            sessions[idx].state = .err;
            return -5;
        }
        @memcpy(out_ptr[0..written], result[0..written]);
        sessions[idx].state = .checked;
        return @intCast(written);
    } else |_| {
        sessions[idx].state = .err;
        return -7;
    }
}

/// Evaluate/run source code via the language service.
/// POSTs to {url}/eval with the source as JSON body.
pub export fn lang_eval(sess_idx: c_int, src_ptr: [*]const u8, src_len: usize, out_ptr: [*]u8, out_len: usize) callconv(.c) i32 {
    var endpoint_buf: [600]u8 = undefined;
    var endpoint_total: usize = 0;
    var src_buf: [16384]u8 = undefined;
    var safe_src_len: usize = 0;

    {
        mutex.lock();
        defer mutex.unlock();

        if (sess_idx < 0 or sess_idx >= MAX_SESSIONS) return -1;
        const idx: usize = @intCast(sess_idx);
        if (!sessions[idx].active) return -1;
        if (sessions[idx].state != .idle and sessions[idx].state != .checked) return -2;
        if (sessions[idx].url_len == 0) return -6;

        const url_slice = sessions[idx].url_buf[0..sessions[idx].url_len];
        const suffix = "/eval";
        if (url_slice.len + suffix.len >= endpoint_buf.len) return -6;
        @memcpy(endpoint_buf[0..url_slice.len], url_slice);
        @memcpy(endpoint_buf[url_slice.len..][0..suffix.len], suffix);
        endpoint_total = url_slice.len + suffix.len;
        endpoint_buf[endpoint_total] = 0;

        safe_src_len = @min(src_len, src_buf.len - 1);
        @memcpy(src_buf[0..safe_src_len], src_ptr[0..safe_src_len]);
        src_buf[safe_src_len] = 0;

        sessions[idx].state = .evaluating;
    }

    const child_result = runCurlPost(
        endpoint_buf[0..endpoint_total :0],
        src_buf[0..safe_src_len :0],
    );

    mutex.lock();
    defer mutex.unlock();

    const idx: usize = @intCast(sess_idx);
    if (!sessions[idx].active) return -1;

    if (child_result) |result| {
        defer std.heap.page_allocator.free(result);
        const written = result.len;
        if (written > out_len) {
            sessions[idx].state = .err;
            return -5;
        }
        @memcpy(out_ptr[0..written], result[0..written]);
        sessions[idx].state = .idle;
        return @intCast(written);
    } else |_| {
        sessions[idx].state = .err;
        return -7;
    }
}

/// Reset all sessions (for testing).
pub export fn lang_reset() void {
    mutex.lock();
    defer mutex.unlock();
    for (&sessions) |*sess| {
        sess.active = false;
        sess.state = .idle;
        sess.url_len = 0;
        sess.name_len = 0;
    }
}

/// Run curl as a child process for an HTTP POST with JSON body.
fn runCurlPost(endpoint: [:0]const u8, body: [:0]const u8) ![]u8 {
    const argv = [_][]const u8{
        "curl", "-sf", "--max-time", "10",
        "-X", "POST", "-H", "Content-Type: application/json",
        "-d", body, endpoint,
    };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const alloc = std.heap.page_allocator;
    var stdout_list: std.ArrayList(u8) = .empty;
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(alloc);

    try child.collectOutput(alloc, &stdout_list, &stderr_list, 65536);
    const term = try child.wait();

    if (term.Exited != 0) {
        stdout_list.deinit(alloc);
        return error.CurlFailed;
    }

    return stdout_list.toOwnedSlice(alloc);
}

// ═══════════════════════════════════════════════════════════════════════
// Standard Cartridge Interface
// ═══════════════════════════════════════════════════════════════════════

pub export fn boj_cartridge_init() c_int {
    lang_reset();
    return 0;
}

pub export fn boj_cartridge_deinit() void {
    lang_reset();
}

pub export fn boj_cartridge_name() [*:0]const u8 {
    return "lang-mcp";
}

pub export fn boj_cartridge_version() [*:0]const u8 {
    return "0.1.0";
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

test "session start and end" {
    lang_reset();
    const name = "test-session";
    const sess = lang_session_start(@intFromEnum(Language.eclexia), name, name.len);
    try std.testing.expect(sess >= 0);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(LangState.idle)), lang_session_state(sess));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Language.eclexia)), lang_session_language(sess));
    try std.testing.expectEqual(@as(c_int, 0), lang_session_end(sess));
}

test "session set URL" {
    lang_reset();
    const name = "url-test";
    const sess = lang_session_start(@intFromEnum(Language.affinescript), name, name.len);
    try std.testing.expect(sess >= 0);
    const url = "http://localhost:9100";
    try std.testing.expectEqual(@as(c_int, 0), lang_session_set_url(sess, url, url.len));
    try std.testing.expectEqual(@as(c_int, 0), lang_session_end(sess));
}

test "cannot double-end session" {
    lang_reset();
    const name = "double-end";
    const sess = lang_session_start(@intFromEnum(Language.betlang), name, name.len);
    _ = lang_session_end(sess);
    try std.testing.expectEqual(@as(c_int, -1), lang_session_end(sess));
}

test "session rejects empty name" {
    lang_reset();
    const sess = lang_session_start(@intFromEnum(Language.mylang), "", 0);
    try std.testing.expectEqual(@as(c_int, -2), sess);
}

test "all 12 languages can start sessions" {
    lang_reset();
    const langs = [_]c_int{ 1, 2, 3, 4, 5, 6, 7, 8 };
    for (langs, 0..) |lang_id, i| {
        _ = i;
        const name = "lang-test";
        const sess = lang_session_start(lang_id, name, name.len);
        try std.testing.expect(sess >= 0);
    }
    // All 8 slots used — next should fail
    const name = "overflow";
    const overflow = lang_session_start(9, name, name.len);
    try std.testing.expectEqual(@as(c_int, -1), overflow);
}

test "session URL rejects empty and overlong" {
    lang_reset();
    const name = "url-reject";
    const sess = lang_session_start(@intFromEnum(Language.phronesis), name, name.len);
    try std.testing.expect(sess >= 0);
    try std.testing.expectEqual(@as(c_int, -6), lang_session_set_url(sess, "", 0));
    var long_url: [URL_BUF_SIZE]u8 = [_]u8{'x'} ** URL_BUF_SIZE;
    try std.testing.expectEqual(@as(c_int, -6), lang_session_set_url(sess, &long_url, long_url.len));
    _ = lang_session_end(sess);
}
