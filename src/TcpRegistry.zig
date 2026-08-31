//! Registry of open TCP/TLS connections for the planned network capability's
//! raw-socket host functions (`tcp_connect`/`tcp_read`/`tcp_write`/
//! `tcp_close`/`tcp_upgrade_tls`, not yet built). Mirrors `WidgetHost`'s
//! `slots`/`id_to_index` registry shape (fixed-capacity slots, monotonic
//! ids, O(1) lookup), but deliberately carries **no `Io.Mutex`**: widgets
//! need one because both the main render thread and the dispatch worker
//! thread touch that registry every frame, but nothing outside a host-
//! function call ever touches a TCP connection, and only one Extism plugin
//! call is ever in flight at a time (see `Runtime.zig`'s own threading
//! model) -- the same assumption `Sqlite.zig`'s single-connection design
//! already relies on, just extended to a multi-connection registry here.
//!
//! Each `Connection`'s `reader` is constructed with a zero-length buffer --
//! not an oversight, the real fix for a genuine `std.Io.net` internal-
//! buffering edge case found and verified during design (see the
//! `natyv-tcp-tls-host-function` memory): with no internal buffer capacity,
//! the specific vtable branch that has the bug becomes structurally
//! unreachable, and every `readVec` call becomes a single direct syscall
//! into whatever destination the caller supplies -- exactly the "guest
//! owns its own buffering" semantics `tcp_read`'s design wants anyway.
//!
//! `writer`'s backing buffer is different: `Stream.Writer` holds a slice
//! into it for the writer's whole lifetime, so it has to be stable,
//! per-connection memory (`write_bufs[idx]`, not pooled or shared).
//! `read_scratch` is the opposite: transient, live only for the duration of
//! one `tcp_read` call, so a single shared buffer suffices -- not even a
//! pool -- given the one-call-at-a-time invariant above.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const TlsMode = @import("Config").TlsMode;
const Tls = @import("Tls.zig");

const Self = @This();

/// Small on purpose -- a real app plausibly wants an IMAP connection and an
/// SMTP connection open at once, not hundreds like widgets.
pub const max_connections = 8;
const write_buf_len = 4096;
pub const read_scratch_len = 8192;

pub const Connection = struct {
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    tls: TlsMode,
    /// Non-null once TLS is actually active on this connection -- either
    /// immediately after `tcp_connect` for a `.implicit` entry, or after a
    /// later `tcp_upgrade_tls` for a `.starttls` one. When set, all real
    /// I/O goes through this instead of `reader`/`writer` above (which
    /// still exist underneath -- `Session` holds its own reader/writer
    /// over the same `stream` for its BIO bridging -- but must not be used
    /// directly anymore, since that would race the same socket bytes
    /// against the TLS layer's own framing).
    tls_session: ?Tls.Session = null,
    /// Owned copy of the hostname `tcp_connect` was given -- needed again
    /// at `tcp_upgrade_tls` time for TLS hostname verification/SNI, which
    /// only happens *after* the plaintext STARTTLS handshake, not at
    /// connect time for a `.starttls` entry. Fixed-size, not heap-owned --
    /// matches this project's own bounded-buffer convention (e.g.
    /// `HostName.max_len`) rather than adding alloc/free bookkeeping for a
    /// short-lived string that's already known to fit.
    host_buf: [net.HostName.max_len]u8 = undefined,
    host_len: u8,
    /// The port `tcp_connect` was given -- needed alongside `host()` at
    /// `tcp_upgrade_tls` time to re-look-up this endpoint's own custom CA
    /// override (see `capabilities/Tcp.zig`'s `findCustomCaPem`), which is
    /// keyed by host:port, not host alone.
    port: u16,

    pub fn host(self: *const Connection) []const u8 {
        return self.host_buf[0..self.host_len];
    }
};

allocator: std.mem.Allocator,
slots: [max_connections]?Connection = @splat(null),
write_bufs: [max_connections][write_buf_len]u8 = undefined,
next_id: u32 = 1,
/// id -> index into `slots`, kept in sync at every real site a slot is ever
/// assigned or freed -- same invariant `WidgetHost.id_to_index` documents.
id_to_index: std.AutoHashMapUnmanaged(u32, usize) = .empty,
/// Shared scratch space for `tcp_read`'s destination buffer -- see the file
/// doc comment for why one buffer (not a pool) is correct here.
read_scratch: [read_scratch_len]u8 = undefined,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub const InsertError = error{RegistryFull};

/// `stream` and `io` are consumed -- ownership of the connection (including
/// eventually closing it) transfers to the registry once this returns a
/// real id. `host` must fit within `Io.net.HostName.max_len` -- guaranteed
/// by construction, since it's the same hostname `HostName.init` already
/// validated during `Tcp.connectFiltered`.
pub fn insert(self: *Self, stream: net.Stream, io: Io, tls: TlsMode, host: []const u8, port: u16) InsertError!u32 {
    std.debug.assert(host.len <= net.HostName.max_len);
    for (&self.slots, 0..) |*slot, idx| {
        if (slot.* == null) {
            const id = self.next_id;
            self.next_id += 1;
            // Inserted into the map *before* the slot itself, so a failed
            // put (OOM) leaves this a clean no-op -- mirrors
            // WidgetHost.insertLockedWithLayout's own precedent.
            self.id_to_index.put(self.allocator, id, idx) catch return error.RegistryFull;
            slot.* = .{
                .stream = stream,
                .reader = stream.reader(io, &.{}),
                .writer = stream.writer(io, &self.write_bufs[idx]),
                .tls = tls,
                .host_len = @intCast(host.len),
                .port = port,
            };
            @memcpy(slot.*.?.host_buf[0..host.len], host);
            return id;
        }
    }
    return error.RegistryFull;
}

/// O(1) via `id_to_index`, same pattern as `WidgetHost.findLocked`.
pub fn find(self: *Self, id: u32) ?*Connection {
    const idx = self.id_to_index.get(id) orelse return null;
    return if (self.slots[idx] != null) &self.slots[idx].? else null;
}

/// Closes the underlying socket and frees the slot. A no-op (not an error)
/// if `id` doesn't name an open connection -- matches `tcp_close`'s planned
/// wire contract of always returning `{"ok": true}`, since closing an
/// already-closed or never-open handle isn't a meaningful failure a guest
/// needs to react to differently.
pub fn close(self: *Self, id: u32, io: Io) void {
    const idx = self.id_to_index.get(id) orelse return;
    if (self.slots[idx]) |*conn| {
        // TLS close_notify writes a final message over the still-open
        // stream, so it must run before the stream itself closes.
        if (conn.tls_session) |*session| session.close();
        conn.stream.close(io);
    }
    self.slots[idx] = null;
    _ = self.id_to_index.remove(id);
}

/// Force-closes every still-open connection (a guest that never called
/// `tcp_close` shouldn't leak a real OS socket past app shutdown). Split
/// out from `deinit` below because it needs a real `Io` to actually call
/// `stream.close`, and `Runtime.deinit()` (the realistic caller of `deinit`
/// at real app shutdown) has no `Io` available to give it -- calling this
/// explicitly is the caller's job whenever an `Io` is actually in hand
/// (e.g. right before dropping a `Runtime` while the app's own `Io` is
/// still alive), not something `deinit` can do unconditionally.
pub fn closeAll(self: *Self, io: Io) void {
    for (&self.slots) |*slot| {
        if (slot.*) |*conn| {
            if (conn.tls_session) |*session| session.close();
            conn.stream.close(io);
        }
        slot.* = null;
    }
}

/// Frees `id_to_index`'s own backing memory -- the fixed-size `slots`/
/// `write_bufs` arrays need no equivalent. Deliberately takes no `Io` (see
/// `closeAll` above for why that's a separate call): real OS sockets left
/// open here get reclaimed by the OS at process exit regardless, the same
/// way any other unclosed fd would be -- only the heap-backed hash map
/// needs deterministic freeing to keep the leak-checked GPA in debug
/// builds quiet, mirroring `WidgetHost.deinit`'s own doc comment on why a
/// hash map needs this and a fixed array doesn't.
pub fn deinit(self: *Self) void {
    self.id_to_index.deinit(self.allocator);
}

// --- Tests: real loopback connections, not mocked, matching this
// project's own established "verify for real" discipline. ---

fn testEchoServer(io: Io, port: u16, expected_msgs: u32) void {
    var addr = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch return;
    defer server.socket.close(io);
    var stream = server.accept(io) catch return;
    defer stream.close(io);

    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    var reader = stream.reader(io, &.{});
    var writer = stream.writer(io, &write_buf);
    var i: u32 = 0;
    while (i < expected_msgs) : (i += 1) {
        var data: [1][]u8 = .{&read_buf};
        const n = reader.interface.readVec(&data) catch break;
        writer.interface.writeAll(read_buf[0..n]) catch break;
        writer.interface.flush() catch break;
    }
}

fn testConnect(io: Io, port: u16) !net.Stream {
    (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }).sleep(io) catch {};
    const host_name = try net.HostName.init("127.0.0.1");
    return host_name.connect(io, port, .{ .mode = .stream });
}

test "insert/find/close round trip over a real loopback connection" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server_future = io.async(testEchoServer, .{ io, 37001, 1 });
    const stream = try testConnect(io, 37001);

    var registry: Self = .init(std.testing.allocator);
    defer { registry.closeAll(io); registry.deinit(); }

    const id = try registry.insert(stream, io, .none, "127.0.0.1", 0);
    try std.testing.expect(registry.find(id) != null);
    try std.testing.expect(registry.find(id + 1) == null); // unknown id

    // Real round trip through the registry's own reader/writer, not the
    // raw `stream` reference (which the registry now owns).
    const conn = registry.find(id).?;
    try conn.writer.interface.writeAll("hi");
    try conn.writer.interface.flush();
    var buf: [8]u8 = undefined;
    var data: [1][]u8 = .{&buf};
    const n = try conn.reader.interface.readVec(&data);
    try std.testing.expectEqualStrings("hi", buf[0..n]);

    registry.close(id, io);
    try std.testing.expect(registry.find(id) == null);

    server_future.await(io);
}

test "registry full, then a slot frees up after close" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var registry: Self = .init(std.testing.allocator);
    defer { registry.closeAll(io); registry.deinit(); }

    const base_port: u16 = 37010;
    var server_futures: [max_connections]Io.Future(void) = undefined;
    var ids: [max_connections]u32 = undefined;

    for (0..max_connections) |i| {
        const port: u16 = base_port + @as(u16, @intCast(i));
        server_futures[i] = io.async(testEchoServer, .{ io, port, 0 });
        const stream = try testConnect(io, port);
        ids[i] = try registry.insert(stream, io, .none, "127.0.0.1", 0);
    }

    // Registry is now full -- one more real connection attempt should be
    // rejected by the registry itself, not by the network.
    const overflow_port: u16 = base_port + max_connections;
    var overflow_server_future = io.async(testEchoServer, .{ io, overflow_port, 0 });
    const overflow_stream = try testConnect(io, overflow_port);
    defer overflow_stream.close(io);
    try std.testing.expectError(error.RegistryFull, registry.insert(overflow_stream, io, .none, "127.0.0.1", 0));
    overflow_server_future.await(io);

    // Freeing one slot makes room again.
    registry.close(ids[0], io);
    const retry_port: u16 = overflow_port + 1;
    var retry_server_future = io.async(testEchoServer, .{ io, retry_port, 0 });
    const retry_stream = try testConnect(io, retry_port);
    const retry_id = try registry.insert(retry_stream, io, .none, "127.0.0.1", 0);
    try std.testing.expect(registry.find(retry_id) != null);
    retry_server_future.await(io);

    for (&server_futures) |*f| f.await(io);
}
