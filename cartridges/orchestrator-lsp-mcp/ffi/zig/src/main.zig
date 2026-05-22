// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// orchestrator-lsp-mcp — Zig FFI bridge for the cross-domain LSP orchestrator.
//
// Implements the ADR-0006 five-symbol cartridge ABI.  The MCP tool layer
// manages a local session table (workspace root + active domain set) and
// delegates actual LSP routing to the Elixir GenLSP adapter via the Erlang
// port protocol (4-byte big-endian length framing over stdin/stdout).
//
// Port lifecycle:
//   boj_cartridge_init   → resets session table; adapter spawned lazily
//   boj_cartridge_invoke → sessions are managed in Zig; lsp_orchestrate_request
//                          forwards to the Elixir adapter via port protocol
//   boj_cartridge_deinit → sends {"cmd":"shutdown"} to adapter and waits
//
// Env vars:
//   BOJ_ORCHESTRATOR_LSP_DIR — path to the adapter/ Mix project root
//   BOJ_ORCHESTRATOR_LSP_CMD — override Mix command (default: "mix run --no-halt")
//
// Domains (indices 0-11, matching poly-*-lsp default ports 9001-9012):
//   0=cloud  1=container  2=iac  3=k8s  4=db  5=queue
//   6=secret 7=git        8=ssg  9=proof 10=observability 11=browser

const std = @import("std");
const shim = @import("cartridge_shim.zig");

// ─── Constants ───────────────────────────────────────────────────────────────

const MAX_SESSIONS: usize = 8;
const MAX_DOMAINS: usize = 12;
const WS_PATH_CAP: usize = 512;
const SESSION_ID_LEN: usize = 13; // "sess-00000001"
const PORT_BUF_CAP: usize = 65536;

const DOMAIN_NAMES = [MAX_DOMAINS][]const u8{
    "cloud", "container", "iac",   "k8s",          "db",    "queue",
    "secret", "git",      "ssg",   "proof",         "observability", "browser",
};

// ─── Session table ───────────────────────────────────────────────────────────

const Session = struct {
    active: bool = false,
    id: [SESSION_ID_LEN]u8 = [_]u8{0} ** SESSION_ID_LEN,
    workspace_root: [WS_PATH_CAP]u8 = [_]u8{0} ** WS_PATH_CAP,
    ws_len: usize = 0,
    /// domains[i] == true when poly-<domain>-lsp is active for this session.
    domains: [MAX_DOMAINS]bool = [_]bool{false} ** MAX_DOMAINS,
};

var sessions: [MAX_SESSIONS]Session = [_]Session{.{}} ** MAX_SESSIONS;
var session_counter: u32 = 0;
var session_mutex: std.Thread.Mutex = .{};

fn nextSessionId(out: *[SESSION_ID_LEN]u8) void {
    session_counter +%= 1;
    _ = std.fmt.bufPrint(out, "sess-{X:0>8}", .{session_counter}) catch {};
}

/// Find session by ID.  Caller must hold `session_mutex`.
fn findSession(id: []const u8) ?*Session {
    const cmp_len = @min(id.len, SESSION_ID_LEN);
    for (&sessions) |*s| {
        if (s.active and std.mem.eql(u8, s.id[0..cmp_len], id[0..cmp_len]))
            return s;
    }
    return null;
}

// ─── Minimal JSON field extraction ───────────────────────────────────────────
//
// Stack-only scanning — no heap allocation, no escape handling.
// Sufficient for the unescaped paths and IDs in our tool schemas.

fn extractString(json: []const u8, field: []const u8, out: []u8) ?[]u8 {
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\"", .{field}) catch return null;

    const pos = std.mem.indexOf(u8, json, key) orelse return null;
    var tail = json[pos + key.len ..];

    tail = std.mem.trimLeft(u8, tail, " \t\r\n");
    if (tail.len == 0 or tail[0] != ':') return null;
    tail = std.mem.trimLeft(u8, tail[1..], " \t\r\n");

    if (tail.len == 0 or tail[0] != '"') return null;
    tail = tail[1..];

    const end = std.mem.indexOf(u8, tail, "\"") orelse return null;
    if (end > out.len) return null;
    @memcpy(out[0..end], tail[0..end]);
    return out[0..end];
}

/// Return true when a domain name string appears in the JSON `domains` array.
fn domainInJson(json: []const u8, domain: []const u8) bool {
    return std.mem.indexOf(u8, json, domain) != null;
}

// ─── Port process ─────────────────────────────────────────────────────────────
//
// A single Elixir adapter process handles all sessions.
// `port_mutex` serialises both spawn and the full send→receive round-trip so
// concurrent invoke calls cannot interleave their messages on the pipe.

var port_child: ?std.process.Child = null;
var port_mutex: std.Thread.Mutex = .{};

/// Spawn the Elixir adapter if not already running.
/// Uses std.heap.page_allocator so the argv slice outlives this call.
/// The tiny allocation (< 512 bytes) is intentionally not freed — it persists
/// for the lifetime of the .so and is reclaimed by the OS when the process exits.
fn ensurePort() void {
    port_mutex.lock();
    defer port_mutex.unlock();
    if (port_child != null) return;

    const dir = std.posix.getenv("BOJ_ORCHESTRATOR_LSP_DIR") orelse
        "cartridges/orchestrator-lsp-mcp/adapter";
    const cmd_str = std.posix.getenv("BOJ_ORCHESTRATOR_LSP_CMD") orelse
        "mix run --no-halt";

    const alloc = std.heap.page_allocator;
    var argv = std.ArrayList([]const u8).init(alloc);
    var tok = std.mem.tokenizeScalar(u8, cmd_str, ' ');
    while (tok.next()) |part| argv.append(part) catch return;
    // argv.toOwnedSlice() would also work; we intentionally leave the ArrayList
    // allocated so proc.argv remains valid for the child's lifetime.

    var proc = std.process.Child.init(argv.items, alloc);
    proc.cwd = dir;
    proc.stdin_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Inherit;

    proc.spawn() catch |err| {
        std.debug.print(
            "[orchestrator-lsp-mcp] warn: adapter spawn failed ({s}): {}\n",
            .{ dir, err },
        );
        return;
    };
    port_child = proc;
}

/// Send a request and receive the response in a single locked operation.
/// Holding the lock for the full round-trip prevents request interleaving from
/// concurrent invoke calls.
///
/// `std.fs.File` is a thin wrapper around an OS file descriptor (an integer),
/// so copying it from the `Child` struct is safe — both copies access the same fd.
fn portRoundTrip(request_json: []const u8, buf: []u8) ![]u8 {
    port_mutex.lock();
    defer port_mutex.unlock();

    // Copy the Child struct; File handles are fd integers — safe to copy.
    const pc = port_child orelse return error.NotConnected;
    var len_buf: [4]u8 = undefined;

    // Send: 4-byte big-endian length + payload (Erlang port protocol).
    const stdin = pc.stdin orelse return error.NotConnected;
    std.mem.writeInt(u32, &len_buf, @intCast(request_json.len), .big);
    try stdin.writeAll(&len_buf);
    try stdin.writeAll(request_json);

    // Receive: 4-byte length + response.
    const stdout = pc.stdout orelse return error.NotConnected;
    try stdout.readNoEof(&len_buf);
    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len > buf.len) return error.ResponseTooLarge;
    try stdout.readNoEof(buf[0..msg_len]);
    return buf[0..msg_len];
}

// ─── Standard ABI symbols ────────────────────────────────────────────────────

export fn boj_cartridge_init() callconv(.c) c_int {
    session_mutex.lock();
    for (&sessions) |*s| s.* = Session{};
    session_counter = 0;
    session_mutex.unlock();
    return 0;
}

export fn boj_cartridge_deinit() callconv(.c) void {
    port_mutex.lock();
    defer port_mutex.unlock();

    // Use `|*c|` so `c` is a pointer to the Child inside the optional.
    // This lets `c.wait()` operate on the actual global state, not a copy.
    if (port_child) |*c| {
        if (c.stdin) |stdin| {
            const msg = "{\"cmd\":\"shutdown\"}";
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(msg.len), .big);
            stdin.writeAll(&len_buf) catch {};
            stdin.writeAll(msg) catch {};
        }
        _ = c.wait() catch {};
    }
    port_child = null;
}

export fn boj_cartridge_name() callconv(.c) [*:0]const u8 {
    return "orchestrator-lsp-mcp";
}

export fn boj_cartridge_version() callconv(.c) [*:0]const u8 {
    return "0.1.0";
}

// ─── Tool: lsp_orchestrate_start ─────────────────────────────────────────────
//
// Input:  {"workspace_root": "/path", "domains": ["git","k8s"]}
//         `domains` is optional — absent or empty means all 12 are active.
// Output: {"session_id":"sess-XXXXXXXX","workspace_root":"/path","domain_count":N}

fn toolStart(args: []const u8, out_buf: [*c]u8, in_out_len: [*c]usize) i32 {
    var ws_buf: [WS_PATH_CAP]u8 = undefined;
    const ws = extractString(args, "workspace_root", &ws_buf) orelse {
        return shim.writeResult(out_buf, in_out_len, "{\"error\":\"missing workspace_root\"}");
    };

    session_mutex.lock();
    defer session_mutex.unlock();

    var slot: ?*Session = null;
    for (&sessions) |*s| if (!s.active) { slot = s; break; };
    const s = slot orelse
        return shim.writeResult(out_buf, in_out_len,
            "{\"error\":\"session_limit_reached\",\"limit\":8}");

    s.* = Session{};
    s.active = true;
    nextSessionId(&s.id);

    const wl = @min(ws.len, WS_PATH_CAP - 1);
    @memcpy(s.workspace_root[0..wl], ws[0..wl]);
    s.ws_len = wl;

    const has_domains_key = std.mem.indexOf(u8, args, "\"domains\"") != null;
    if (!has_domains_key) {
        for (&s.domains) |*d| d.* = true;
    } else {
        for (DOMAIN_NAMES, 0..) |dn, i| s.domains[i] = domainInJson(args, dn);
    }

    var count: usize = 0;
    for (s.domains) |d| if (d) count += 1;

    var resp_buf: [512]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf,
        "{{\"session_id\":\"{s}\",\"workspace_root\":\"{s}\",\"domain_count\":{d}}}",
        .{ s.id, s.workspace_root[0..s.ws_len], count },
    ) catch return shim.RC_RUNTIME_ERROR;
    return shim.writeResult(out_buf, in_out_len, resp);
}

// ─── Tool: lsp_orchestrate_stop ──────────────────────────────────────────────
//
// Input:  {"session_id":"sess-XXXXXXXX"}
// Output: {"session_id":"sess-XXXXXXXX","stopped":true}

fn toolStop(args: []const u8, out_buf: [*c]u8, in_out_len: [*c]usize) i32 {
    var id_buf: [SESSION_ID_LEN + 4]u8 = undefined;
    const id_slice = extractString(args, "session_id", &id_buf) orelse
        return shim.writeResult(out_buf, in_out_len, "{\"error\":\"missing session_id\"}");

    session_mutex.lock();
    defer session_mutex.unlock();

    const s = findSession(id_slice) orelse {
        var eb: [128]u8 = undefined;
        const err = std.fmt.bufPrint(&eb,
            "{{\"error\":\"session_not_found\",\"session_id\":\"{s}\"}}",
            .{id_slice},
        ) catch return shim.RC_RUNTIME_ERROR;
        return shim.writeResult(out_buf, in_out_len, err);
    };

    var resp_buf: [128]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf,
        "{{\"session_id\":\"{s}\",\"stopped\":true}}", .{s.id},
    ) catch return shim.RC_RUNTIME_ERROR;

    s.* = Session{};
    return shim.writeResult(out_buf, in_out_len, resp);
}

// ─── Tool: lsp_orchestrate_status ────────────────────────────────────────────
//
// Input:  {"session_id":"sess-XXXXXXXX"}
// Output: {"session_id":"...","workspace_root":"...","domains":{<name>:<state>,...}}
//
// Domain state is "active" or "inactive".  Live health checks from the adapter
// are a future enhancement (requires the port to be running).

fn toolStatus(args: []const u8, out_buf: [*c]u8, in_out_len: [*c]usize) i32 {
    var id_buf: [SESSION_ID_LEN + 4]u8 = undefined;
    const id_slice = extractString(args, "session_id", &id_buf) orelse
        return shim.writeResult(out_buf, in_out_len, "{\"error\":\"missing session_id\"}");

    session_mutex.lock();
    defer session_mutex.unlock();

    const s = findSession(id_slice) orelse {
        var eb: [128]u8 = undefined;
        const err = std.fmt.bufPrint(&eb,
            "{{\"error\":\"session_not_found\",\"session_id\":\"{s}\"}}",
            .{id_slice},
        ) catch return shim.RC_RUNTIME_ERROR;
        return shim.writeResult(out_buf, in_out_len, err);
    };

    var domain_json: [512]u8 = undefined;
    var off: usize = 0;
    domain_json[off] = '{'; off += 1;
    for (DOMAIN_NAMES, 0..) |dn, i| {
        if (i > 0) { domain_json[off] = ','; off += 1; }
        const state = if (s.domains[i]) "active" else "inactive";
        const seg = std.fmt.bufPrint(domain_json[off..], "\"{s}\":\"{s}\"", .{ dn, state })
            catch return shim.RC_RUNTIME_ERROR;
        off += seg.len;
    }
    domain_json[off] = '}'; off += 1;

    var resp_buf: [1024]u8 = undefined;
    const resp = std.fmt.bufPrint(&resp_buf,
        "{{\"session_id\":\"{s}\",\"workspace_root\":\"{s}\",\"domains\":{s}}}",
        .{ s.id, s.workspace_root[0..s.ws_len], domain_json[0..off] },
    ) catch return shim.RC_RUNTIME_ERROR;
    return shim.writeResult(out_buf, in_out_len, resp);
}

// ─── Tool: lsp_orchestrate_request ───────────────────────────────────────────
//
// Input:  {"session_id":"...","method":"textDocument/completion","params":{...}}
// Output: merged LSP response from the Elixir adapter (or structured error).
//
// The full LSP JSON-RPC round-trip is forwarded to the adapter so it can fan
// the request out to the correct domain server(s) and merge the responses.
// If the adapter is not running, returns an explicit offline error.

fn toolRequest(args: []const u8, out_buf: [*c]u8, in_out_len: [*c]usize) i32 {
    // Validate session exists before touching the port.
    var id_buf: [SESSION_ID_LEN + 4]u8 = undefined;
    const id_slice = extractString(args, "session_id", &id_buf) orelse
        return shim.writeResult(out_buf, in_out_len, "{\"error\":\"missing session_id\"}");

    {
        session_mutex.lock();
        defer session_mutex.unlock();
        _ = findSession(id_slice) orelse {
            var eb: [128]u8 = undefined;
            const err = std.fmt.bufPrint(&eb,
                "{{\"error\":\"session_not_found\",\"session_id\":\"{s}\"}}",
                .{id_slice},
            ) catch return shim.RC_RUNTIME_ERROR;
            return shim.writeResult(out_buf, in_out_len, err);
        };
    }

    // Wrap the MCP args in the adapter's port envelope.
    var req_buf: [PORT_BUF_CAP]u8 = undefined;
    const request = std.fmt.bufPrint(&req_buf,
        "{{\"cmd\":\"lsp_orchestrate_request\",\"args\":{s}}}", .{args},
    ) catch return shim.RC_RUNTIME_ERROR;

    // Lazily spawn the Elixir adapter.
    ensurePort();

    // Forward to the adapter.  On transport failure, return a structured error
    // so the caller can display a meaningful message rather than a crash.
    var resp_buf: [PORT_BUF_CAP]u8 = undefined;
    const resp = portRoundTrip(request, &resp_buf) catch |err| {
        var eb: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&eb,
            "{{\"error\":\"adapter_unavailable\",\"detail\":\"{s}\"," ++
            "\"hint\":\"set BOJ_ORCHESTRATOR_LSP_DIR and start the adapter\"}}",
            .{@errorName(err)},
        ) catch return shim.RC_RUNTIME_ERROR;
        return shim.writeResult(out_buf, in_out_len, msg);
    };

    return shim.writeResult(out_buf, in_out_len, resp);
}

// ─── ADR-0006 dispatch ────────────────────────────────────────────────────────

export fn boj_cartridge_invoke(
    tool_name: [*c]const u8,
    json_args: [*c]const u8,
    out_buf: [*c]u8,
    in_out_len: [*c]usize,
) callconv(.c) i32 {
    if (shim.invokeArgsNull(tool_name, out_buf, in_out_len)) return shim.RC_BAD_ARGS;

    const args: []const u8 = if (json_args != null)
        std.mem.span(@as([*:0]const u8, @ptrCast(json_args)))
    else
        "{}";

    if (shim.toolIs(tool_name, "lsp_orchestrate_start"))  return toolStart(args, out_buf, in_out_len);
    if (shim.toolIs(tool_name, "lsp_orchestrate_stop"))   return toolStop(args, out_buf, in_out_len);
    if (shim.toolIs(tool_name, "lsp_orchestrate_status")) return toolStatus(args, out_buf, in_out_len);
    if (shim.toolIs(tool_name, "lsp_orchestrate_request")) return toolRequest(args, out_buf, in_out_len);

    return shim.RC_UNKNOWN_TOOL;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "session start returns session_id and domain_count" {
    _ = boj_cartridge_init();
    var buf: [512]u8 = undefined;
    var len: usize = buf.len;

    const rc = boj_cartridge_invoke(
        "lsp_orchestrate_start",
        "{\"workspace_root\":\"/tmp/ws\"}",
        &buf, &len,
    );
    try std.testing.expectEqual(@as(i32, 0), rc);
    const resp = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, resp, "session_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "domain_count") != null);
}

test "start with explicit domains respects selection" {
    _ = boj_cartridge_init();
    var buf: [512]u8 = undefined;
    var len: usize = buf.len;

    const rc = boj_cartridge_invoke(
        "lsp_orchestrate_start",
        "{\"workspace_root\":\"/ws\",\"domains\":[\"git\",\"k8s\"]}",
        &buf, &len,
    );
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "\"domain_count\":2") != null);
}

test "status returns all domain states for a valid session" {
    _ = boj_cartridge_init();
    var buf: [2048]u8 = undefined;
    var len: usize = buf.len;

    _ = boj_cartridge_invoke(
        "lsp_orchestrate_start",
        "{\"workspace_root\":\"/ws\"}",
        &buf, &len,
    );
    var id_buf: [SESSION_ID_LEN + 4]u8 = undefined;
    const sid = extractString(buf[0..len], "session_id", &id_buf).?;

    var args_buf: [128]u8 = undefined;
    const status_args = try std.fmt.bufPrint(
        &args_buf, "{{\"session_id\":\"{s}\"}}", .{sid});

    var len2: usize = buf.len;
    const rc = boj_cartridge_invoke("lsp_orchestrate_status", status_args.ptr, &buf, &len2);
    try std.testing.expectEqual(@as(i32, 0), rc);
    const resp = buf[0..len2];
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"cloud\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"browser\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"active\"") != null);
}

test "start then stop releases the slot" {
    _ = boj_cartridge_init();
    var buf: [512]u8 = undefined;
    var len: usize = buf.len;

    _ = boj_cartridge_invoke(
        "lsp_orchestrate_start",
        "{\"workspace_root\":\"/ws\"}",
        &buf, &len,
    );
    var id_buf: [SESSION_ID_LEN + 4]u8 = undefined;
    const sid = extractString(buf[0..len], "session_id", &id_buf).?;

    var stop_args_buf: [128]u8 = undefined;
    const stop_args = try std.fmt.bufPrint(
        &stop_args_buf, "{{\"session_id\":\"{s}\"}}", .{sid});

    var len2: usize = buf.len;
    const rc = boj_cartridge_invoke("lsp_orchestrate_stop", stop_args.ptr, &buf, &len2);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len2], "\"stopped\":true") != null);
}

test "stop with unknown session_id returns error" {
    _ = boj_cartridge_init();
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke(
        "lsp_orchestrate_stop",
        "{\"session_id\":\"sess-DEADBEEF\"}",
        &buf, &len,
    );
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "\"error\"") != null);
}

test "request without adapter returns structured offline error" {
    _ = boj_cartridge_init();
    var buf: [512]u8 = undefined;
    var len: usize = buf.len;

    _ = boj_cartridge_invoke(
        "lsp_orchestrate_start",
        "{\"workspace_root\":\"/ws\"}",
        &buf, &len,
    );
    var id_buf: [SESSION_ID_LEN + 4]u8 = undefined;
    const sid = extractString(buf[0..len], "session_id", &id_buf).?;

    var args_buf: [256]u8 = undefined;
    const req_args = try std.fmt.bufPrint(
        &args_buf,
        "{{\"session_id\":\"{s}\",\"method\":\"textDocument/hover\",\"params\":{{}}}}",
        .{sid});

    var len2: usize = buf.len;
    const rc = boj_cartridge_invoke("lsp_orchestrate_request", req_args.ptr, &buf, &len2);
    // Returns RC_SUCCESS with an error payload — not RC_RUNTIME_ERROR.
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len2], "adapter_unavailable") != null);
}

test "session table enforces MAX_SESSIONS limit" {
    _ = boj_cartridge_init();
    var buf: [256]u8 = undefined;

    for (0..MAX_SESSIONS) |_| {
        var len: usize = buf.len;
        const rc = boj_cartridge_invoke(
            "lsp_orchestrate_start", "{\"workspace_root\":\"/ws\"}", &buf, &len);
        try std.testing.expectEqual(@as(i32, 0), rc);
    }
    // One more should hit the limit.
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke(
        "lsp_orchestrate_start", "{\"workspace_root\":\"/ws\"}", &buf, &len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "session_limit_reached") != null);
}

test "unknown tool returns RC_UNKNOWN_TOOL" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke("nonexistent_tool", "{}", &buf, &len);
    try std.testing.expectEqual(shim.RC_UNKNOWN_TOOL, rc);
}

test "null tool_name returns RC_BAD_ARGS" {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    const rc = boj_cartridge_invoke(null, "{}", &buf, &len);
    try std.testing.expectEqual(shim.RC_BAD_ARGS, rc);
}

test "extractString: basic case" {
    const json = "{\"key\":\"value\",\"other\":\"x\"}";
    var out: [64]u8 = undefined;
    const r = extractString(json, "key", &out).?;
    try std.testing.expectEqualStrings("value", r);
}

test "extractString: absent field returns null" {
    const json = "{\"other\":\"x\"}";
    var out: [64]u8 = undefined;
    try std.testing.expect(extractString(json, "key", &out) == null);
}

test "domainInJson: present and absent" {
    const json = "{\"domains\":[\"git\",\"k8s\"]}";
    try std.testing.expect(domainInJson(json, "git"));
    try std.testing.expect(domainInJson(json, "k8s"));
    try std.testing.expect(!domainInJson(json, "cloud"));
}
