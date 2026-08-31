//! TCP capability: registers `tcp_connect`/`tcp_read`/`tcp_write`/
//! `tcp_close`/`tcp_upgrade_tls` as Extism host functions over a small
//! registry of open connections (`TcpRegistry.zig`). Real connection/
//! allowlist/SSRF-filtering logic lives in `Tcp.zig`, and the real TLS
//! handshake lives in `Tls.zig` (a genuine mbedTLS-backed client, verified
//! against real public TLS servers) -- both kept separate and
//! independently testable, this file is just the guest-memory/JSON ABI
//! glue, the same split `Sqlite.zig`/`capabilities/Sqlite.zig` already
//! establishes.
//!
//! `.implicit` connections (IMAPS-style) hand shake immediately in
//! `tcp_connect`, before the handle is ever returned to the guest.
//! `.starttls` connections stay plaintext until the guest explicitly calls
//! `tcp_upgrade_tls` (after itself sending `STARTTLS` and reading the
//! server's plaintext OK via ordinary `tcp_read`). Once `tls_session` is
//! active on a `Connection`, `tcp_read`/`tcp_write` route through it
//! instead of the connection's plain `reader`/`writer`.
//!
//! A dev-supplied custom CA (`allowed_sockets[].ca_cert_path`) is resolved
//! and staged into `embedded_ca_certs.json` by `cli/main.zig`/`Bundle.zig`
//! at real `natyv build` time (see `EmbeddedWasmPresent.zig`'s own doc
//! comment) -- `findCustomCaPem` below parses that embedded JSON at
//! connect/upgrade time and looks up this endpoint's own PEM by exact
//! host:port match, falling back to `Tls.zig`'s bundled Mozilla CA store
//! when no override was staged (an empty `embedded_ca_certs.json`, which is
//! always the case in a normal, non-bundled dev build -- there's no live
//! disk-read fallback for local iteration yet, a known, deliberate scope
//! boundary).
//!
//! Wire contract (JSON both directions, base64 for binary payloads --
//! matches `Sqlite.zig`'s own convention, see `natyv-tcp-tls-host-function`
//! memory):
//!   tcp_connect:     in {"host":"...","port":N}        out {"handle":N} | {"error":"..."}
//!   tcp_upgrade_tls: in {"handle":N}                    out {"ok":true} | {"error":"..."}
//!   tcp_read:        in {"handle":N,"max_len":N}        out {"data":"<base64>"} | {"eof":true} | {"error":"..."}
//!   tcp_write:       in {"handle":N,"data":"<base64>"}  out {"ok":true} | {"error":"..."}
//!   tcp_close:       in {"handle":N}                    out {"ok":true}
//!
//! `current_io`/`io()` mirror `WidgetHost`'s exact stash pattern: host
//! function callbacks are raw `callconv(.c)` and can't carry a Zig `Io`
//! value across the C ABI, so `Runtime.call` stashes it here immediately
//! before `extism_plugin_call` and unstashes after -- safe for the same
//! reason `WidgetHost`'s own copy of this pattern is: only one plugin call
//! is ever in flight at a time.

const std = @import("std");
const Io = std.Io;
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const Config = @import("Config");
const Tcp = @import("../Tcp.zig");
const TcpRegistry = @import("../TcpRegistry.zig");
const Tls = @import("../Tls.zig");
// Named module, injected via build.zig the same way `main.zig` gets it --
// only ever resolvable when this file is reached through `Runtime.zig`'s
// own real build target (natyv-core itself, or runtime_tests/
// runtime_test_tests), never through Tcp.zig/TcpRegistry.zig/Tls.zig's own
// independent standalone test roots, which don't have it wired in.
const EmbeddedWasm = @import("EmbeddedWasm");

const Self = @This();

pub const host_function_count = 5;

/// Default for how long `tcp_connect` waits before giving up on every
/// candidate address -- see `Tcp.raceConnect`'s own manual-timeout-race
/// design. Overridable per endpoint via `allowed_sockets[].timeout_secs`
/// (see `Config.AllowedSocket`'s own doc comment); this is just the
/// fallback when an entry doesn't set one.
const default_connect_timeout_secs: i64 = 10;

allocator: std.mem.Allocator,
allowed_sockets: []const Config.AllowedSocket,
registry: TcpRegistry,
current_io: ?Io = null,

pub fn init(allocator: std.mem.Allocator, allowed_sockets: []const Config.AllowedSocket) Self {
    return .{
        .allocator = allocator,
        .allowed_sockets = allowed_sockets,
        .registry = .init(allocator),
    };
}

/// Frees the registry's own heap-backed bookkeeping. Deliberately doesn't
/// close any still-open sockets -- see `TcpRegistry.closeAll`'s own doc
/// comment for why that needs a separate, explicit call with a real `Io`
/// in hand, which `Runtime.deinit()` doesn't have.
pub fn deinit(self: *Self) void {
    self.registry.deinit();
}

/// `pub` so `Runtime.call` can stash into it -- see the file doc comment.
pub fn io(self: *Self) Io {
    return self.current_io orelse unreachable;
}

pub fn registerInto(self: *Self, funcs_out: []?*const c.ExtismFunction) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    funcs_out[0] = c.extism_function_new("tcp_connect", &in_types[0], 1, &out_types[0], 1, connectHostFn, self, null);
    funcs_out[1] = c.extism_function_new("tcp_read", &in_types[0], 1, &out_types[0], 1, readHostFn, self, null);
    funcs_out[2] = c.extism_function_new("tcp_write", &in_types[0], 1, &out_types[0], 1, writeHostFn, self, null);
    funcs_out[3] = c.extism_function_new("tcp_close", &in_types[0], 1, &out_types[0], 1, closeHostFn, self, null);
    funcs_out[4] = c.extism_function_new("tcp_upgrade_tls", &in_types[0], 1, &out_types[0], 1, upgradeTlsHostFn, self, null);
    return host_function_count;
}

const ConnectRequest = struct {
    host: []const u8,
    port: u16,
};

const CaCertEntry = struct {
    host: []const u8,
    port: u16,
    pem: []const u8,
};

/// Looks up a dev-supplied custom CA for `host:port` in the real embedded
/// data `cli/main.zig`/`Bundle.zig` staged at build time -- see the file
/// doc comment. Thin wrapper over `findCaPemInJson` below (kept separate
/// so the real JSON-parsing/matching logic is testable without needing
/// `embedded_ca_certs.json` to actually contain something interesting at
/// compile time -- it's normally just `[]`).
fn findCustomCaPem(allocator: std.mem.Allocator, host: []const u8, port: u16) ?[:0]const u8 {
    return findCaPemInJson(allocator, EmbeddedWasm.ca_certs_bytes, host, port);
}

/// Returns `null` (use `Tls.zig`'s bundled default) when nothing matches
/// `host:port` in `json`, which is the normal case for every endpoint that
/// doesn't set `ca_cert_path`, and for every endpoint at all when `json` is
/// empty (always true in a non-bundled dev build). Caller owns the
/// returned buffer.
fn findCaPemInJson(allocator: std.mem.Allocator, json: []const u8, host: []const u8, port: u16) ?[:0]const u8 {
    if (json.len == 0) return null;
    const parsed = std.json.parseFromSlice([]const CaCertEntry, allocator, json, .{}) catch |err| {
        std.debug.print("[tcp] failed to parse embedded_ca_certs.json: {}\n", .{err});
        return null;
    };
    defer parsed.deinit();
    for (parsed.value) |entry| {
        if (entry.port == port and std.ascii.eqlIgnoreCase(entry.host, host)) {
            return allocator.dupeZ(u8, entry.pem) catch return null;
        }
    }
    return null;
}

test "findCaPemInJson: matches by exact host:port, case-insensitive host, ignores others" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {"host": "internal.example.com", "port": 993, "pem": "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n"},
        \\  {"host": "other.example.com", "port": 587, "pem": "OTHER-PEM"}
        \\]
    ;
    const found = findCaPemInJson(allocator, json, "INTERNAL.EXAMPLE.COM", 993).?; // case-insensitive
    defer allocator.free(found);
    try std.testing.expectEqualStrings("-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n", found);
    try std.testing.expectEqual(@as(u8, 0), found[found.len]); // real NUL terminator, not just a slice length claim

    try std.testing.expect(findCaPemInJson(allocator, json, "internal.example.com", 587) == null); // right host, wrong port
    try std.testing.expect(findCaPemInJson(allocator, json, "unlisted.example.com", 993) == null); // not present at all
}

test "findCaPemInJson: empty embedded data (the normal case) returns null without parsing" {
    const allocator = std.testing.allocator;
    try std.testing.expect(findCaPemInJson(allocator, "", "imap.gmail.com", 993) == null);
    try std.testing.expect(findCaPemInJson(allocator, "[]", "imap.gmail.com", 993) == null);
}

fn connectHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(ConnectRequest, self.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();
    const req = parsed.value;

    const matched = Tcp.matchAllowedSocket(self.allowed_sockets, req.host, req.port) orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "{s}:{d} is not in allowed_sockets", .{ req.host, req.port });
        return;
    };

    const timeout_secs = matched.timeout_secs orelse default_connect_timeout_secs;
    const call_io = self.io();
    const stream = Tcp.connectFiltered(call_io, req.host, req.port, timeout_secs) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "connect failed: {}", .{err});
        return;
    };
    const id = self.registry.insert(stream, call_io, matched.tls, req.host, req.port) catch |err| {
        stream.close(call_io);
        host_fn_util.writeErrorJson(plugin, &outputs[0], "{}", .{err});
        return;
    };

    if (matched.tls == .implicit) {
        const hostname_z = self.allocator.dupeZ(u8, req.host) catch {
            self.registry.close(id, call_io);
            host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
            return;
        };
        defer self.allocator.free(hostname_z);
        const custom_ca = findCustomCaPem(self.allocator, req.host, req.port);
        defer if (custom_ca) |ca| self.allocator.free(ca);
        const conn = self.registry.find(id).?;
        conn.tls_session = Tls.Session.handshake(conn.stream, call_io, hostname_z, custom_ca) catch |err| {
            self.registry.close(id, call_io);
            host_fn_util.writeErrorJson(plugin, &outputs[0], "tls handshake failed: {}", .{err});
            return;
        };
    }

    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"handle\":{d}}}", .{id}) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

const UpgradeTlsRequest = struct {
    handle: u32,
};

fn upgradeTlsHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(UpgradeTlsRequest, self.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const conn = self.registry.find(parsed.value.handle) orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "unknown handle {d}", .{parsed.value.handle});
        return;
    };
    if (conn.tls_session != null) {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "already upgraded to tls", .{});
        return;
    }
    if (conn.tls != .starttls) {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "this connection was not configured for starttls", .{});
        return;
    }

    const call_io = self.io();
    const hostname_z = self.allocator.dupeZ(u8, conn.host()) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    };
    defer self.allocator.free(hostname_z);

    const custom_ca = findCustomCaPem(self.allocator, conn.host(), conn.port);
    defer if (custom_ca) |ca| self.allocator.free(ca);
    conn.tls_session = Tls.Session.handshake(conn.stream, call_io, hostname_z, custom_ca) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "tls handshake failed: {}", .{err});
        return;
    };
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{\"ok\":true}");
}

const ReadRequest = struct {
    handle: u32,
    max_len: usize,
};

const read_b64_buf_len = std.base64.standard.Encoder.calcSize(TcpRegistry.read_scratch_len);

fn readHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(ReadRequest, self.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();
    const req = parsed.value;

    const conn = self.registry.find(req.handle) orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "unknown handle {d}", .{req.handle});
        return;
    };

    // One raw read, not "fill max_len" -- the guest owns its own buffering,
    // matching the verified zero-length-reader-buffer design (see
    // natyv-tcp-tls-host-function memory). Routes through the active TLS
    // session once one exists (see the file doc comment for why the plain
    // reader must not be touched anymore at that point).
    const want = @min(req.max_len, self.registry.read_scratch.len);
    const n = if (conn.tls_session) |*session|
        session.read(self.registry.read_scratch[0..want]) catch |err| {
            host_fn_util.writeErrorJson(plugin, &outputs[0], "read failed: {}", .{err});
            return;
        }
    else read: {
        var data: [1][]u8 = .{self.registry.read_scratch[0..want]};
        break :read conn.reader.interface.readVec(&data) catch |err| switch (err) {
            error.EndOfStream => {
                host_fn_util.writeGuestBytes(plugin, &outputs[0], "{\"eof\":true}");
                return;
            },
            else => {
                host_fn_util.writeErrorJson(plugin, &outputs[0], "read failed: {}", .{err});
                return;
            },
        };
    };
    if (n == 0) {
        // Tls.Session.read's own 0-means-closed convention (see its doc
        // comment) -- the plain branch above already returned early for
        // its own EOF case, so reaching here with n == 0 only happens via
        // the TLS branch.
        host_fn_util.writeGuestBytes(plugin, &outputs[0], "{\"eof\":true}");
        return;
    }

    var b64_buf: [read_b64_buf_len]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64_buf, self.registry.read_scratch[0..n]);
    // Base64's alphabet (A-Za-z0-9+/=) never needs JSON escaping.
    const response = std.fmt.allocPrint(self.allocator, "{{\"data\":\"{s}\"}}", .{encoded}) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    };
    defer self.allocator.free(response);
    host_fn_util.writeGuestBytes(plugin, &outputs[0], response);
}

const WriteRequest = struct {
    handle: u32,
    data: []const u8,
};

fn writeHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(WriteRequest, self.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();
    const req = parsed.value;

    const conn = self.registry.find(req.handle) orelse {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "unknown handle {d}", .{req.handle});
        return;
    };

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(req.data) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "invalid base64", .{});
        return;
    };
    const decoded = self.allocator.alloc(u8, decoded_len) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    };
    defer self.allocator.free(decoded);
    decoder.decode(decoded, req.data) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "invalid base64", .{});
        return;
    };

    if (conn.tls_session) |*session| {
        session.write(decoded) catch |err| {
            host_fn_util.writeErrorJson(plugin, &outputs[0], "write failed: {}", .{err});
            return;
        };
    } else {
        conn.writer.interface.writeAll(decoded) catch |err| {
            host_fn_util.writeErrorJson(plugin, &outputs[0], "write failed: {}", .{err});
            return;
        };
        conn.writer.interface.flush() catch |err| {
            host_fn_util.writeErrorJson(plugin, &outputs[0], "flush failed: {}", .{err});
            return;
        };
    }
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{\"ok\":true}");
}

const CloseRequest = struct {
    handle: u32,
};

fn closeHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(CloseRequest, self.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();

    self.registry.close(parsed.value.handle, self.io());
    host_fn_util.writeGuestBytes(plugin, &outputs[0], "{\"ok\":true}");
}
