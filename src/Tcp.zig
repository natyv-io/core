//! Real connection logic behind the planned `tcp_connect` host function --
//! deliberately separate from `capabilities/Tcp.zig`'s Extism ABI glue, the
//! same split `Sqlite.zig`/`capabilities/Sqlite.zig` already establishes:
//! this file is plain, directly testable Zig, no guest-memory/plugin
//! plumbing at all.
//!
//! Split into two layers on purpose, so both halves stay independently
//! testable with real connections and no live internet dependency:
//!   - `raceConnect` -- given a list of already-resolved candidate
//!     addresses, races real connects to all of them concurrently (mirrors
//!     `std.Io.net.HostName.connectMany`'s own internal pattern -- see the
//!     `natyv-tcp-tls-host-function` memory for why this couldn't just be
//!     `HostName.connect` directly) plus a manual queue-race timeout (see
//!     the same memory for why `IpAddress.ConnectOptions.timeout` must
//!     never be used -- it panics on this Zig version's POSIX backend).
//!     Doesn't know or care about allowlists/private ranges; testable
//!     directly against real loopback listeners.
//!   - `connectFiltered` -- the real pipeline `tcp_connect` actually calls:
//!     resolve via `HostName.lookup`, reject any resolved address
//!     `PrivateRanges.isReserved` flags (the real SSRF mitigation), then
//!     `raceConnect` whatever survives. Because loopback (127.0.0.0/8) is
//!     itself one of the blocked ranges, this can't be happy-path tested
//!     against a local listener the usual way -- instead, the real test
//!     here confirms `connectFiltered("127.0.0.1", ...)` is *rejected*,
//!     which is exactly the end-to-end security property this exists to
//!     prove, using nothing but loopback.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const PrivateRanges = @import("PrivateRanges.zig");
const Config = @import("Config");

/// Exact host+port match against `conf.natyv.json`'s `network.tcp.
/// allowed_sockets` -- no wildcards, no partial matching (a guest passing a
/// raw IP literal simply won't match a hostname-keyed entry). Hostnames are
/// case-insensitive per DNS semantics (RFC 4343), so comparison is too.
pub fn matchAllowedSocket(allowed: []const Config.AllowedSocket, host: []const u8, port: u16) ?Config.AllowedSocket {
    for (allowed) |entry| {
        if (entry.port == port and std.ascii.eqlIgnoreCase(entry.host, host)) return entry;
    }
    return null;
}

const max_candidates = 32;

const RaceOutcome = union(enum) {
    connected: net.Stream,
    failed: anyerror,
    timed_out: void,
};

fn connectOneTask(io: Io, address: net.IpAddress, queue: *Io.Queue(RaceOutcome)) void {
    const result = address.connect(io, .{ .mode = .stream });
    const item: RaceOutcome = if (result) |stream| .{ .connected = stream } else |err| .{ .failed = err };
    queue.putOne(io, item) catch {
        // Lost the race after already succeeding -- don't leak the socket.
        if (item == .connected) item.connected.close(io);
    };
}

fn timeoutTask(io: Io, secs: i64, queue: *Io.Queue(RaceOutcome)) void {
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(secs), .clock = .awake } };
    timeout.sleep(io) catch return; // canceled: something else already finished
    queue.putOne(io, .timed_out) catch {};
}

pub const RaceConnectError = error{ NoCandidates, AllConnectsFailed, Timeout };

/// Races a real connect to every candidate concurrently, bounded by
/// `timeout_secs`; returns whichever connects first and cancels the rest.
/// Knows nothing about allowlists or private ranges -- see the file doc
/// comment for why that's deliberate.
pub fn raceConnect(io: Io, candidates: []const net.IpAddress, timeout_secs: i64) !net.Stream {
    if (candidates.len == 0) return error.NoCandidates;
    std.debug.assert(candidates.len <= max_candidates);

    var race_buf: [max_candidates + 1]RaceOutcome = undefined;
    var race_queue: Io.Queue(RaceOutcome) = .init(&race_buf);

    var connect_futures: [max_candidates]Io.Future(void) = undefined;
    for (candidates, 0..) |addr, i| {
        connect_futures[i] = io.async(connectOneTask, .{ io, addr, &race_queue });
    }
    var timeout_future = io.async(timeoutTask, .{ io, timeout_secs, &race_queue });
    defer {
        for (connect_futures[0..candidates.len]) |*f| f.cancel(io);
        timeout_future.cancel(io);
    }

    var last_err: anyerror = error.AllConnectsFailed;
    var attempts_left = candidates.len;
    while (attempts_left > 0) {
        const outcome = race_queue.getOne(io) catch break;
        switch (outcome) {
            .connected => |stream| return stream,
            .failed => |err| {
                last_err = err;
                attempts_left -= 1;
            },
            .timed_out => return error.Timeout,
        }
    }
    return last_err;
}

pub const ConnectFilteredError = error{NoAllowedAddress} || net.HostName.LookupError || RaceConnectError;

/// The real pipeline `tcp_connect` calls: resolve, drop anything
/// `PrivateRanges.isReserved` flags, race-connect what's left. See the file
/// doc comment for why this can't be happy-path tested against a loopback
/// listener the usual way.
pub fn connectFiltered(io: Io, host: []const u8, port: u16, timeout_secs: i64) !net.Stream {
    const host_name = try net.HostName.init(host);

    var lookup_buf: [max_candidates]net.HostName.LookupResult = undefined;
    var lookup_queue: Io.Queue(net.HostName.LookupResult) = .init(&lookup_buf);
    var canon_buf: [net.HostName.max_len]u8 = undefined;
    var lookup_future = io.async(net.HostName.lookup, .{ host_name, io, &lookup_queue, .{
        .port = port,
        .canonical_name_buffer = &canon_buf,
    } });
    defer lookup_future.cancel(io) catch {};

    var candidates: [max_candidates]net.IpAddress = undefined;
    var candidate_count: usize = 0;
    while (lookup_queue.getOne(io)) |result| switch (result) {
        .address => |addr| {
            if (!PrivateRanges.isReserved(addr) and candidate_count < candidates.len) {
                candidates[candidate_count] = addr;
                candidate_count += 1;
            }
        },
        .canonical_name => {},
    } else |err| switch (err) {
        error.Canceled => |e| return e,
        error.Closed => try lookup_future.await(io),
    }

    if (candidate_count == 0) return error.NoAllowedAddress;
    return raceConnect(io, candidates[0..candidate_count], timeout_secs);
}

test "matchAllowedSocket: exact host+port match, case-insensitive, no wildcards" {
    const allowed = [_]Config.AllowedSocket{
        .{ .host = "imap.gmail.com", .port = 993, .tls = .implicit },
        .{ .host = "smtp.gmail.com", .port = 587, .tls = .starttls },
    };
    try std.testing.expect(matchAllowedSocket(&allowed, "imap.gmail.com", 993) != null);
    try std.testing.expect(matchAllowedSocket(&allowed, "IMAP.GMAIL.COM", 993) != null); // case-insensitive
    try std.testing.expect(matchAllowedSocket(&allowed, "imap.gmail.com", 143) == null); // wrong port
    try std.testing.expect(matchAllowedSocket(&allowed, "evil.example.com", 993) == null); // not listed
    try std.testing.expect(matchAllowedSocket(&allowed, "8.8.8.8", 993) == null); // raw IP never matches a hostname entry
    const match = matchAllowedSocket(&allowed, "smtp.gmail.com", 587).?;
    try std.testing.expectEqual(Config.TlsMode.starttls, match.tls);
}

fn testListener(io: Io, port: u16) void {
    var addr = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch return;
    defer server.socket.close(io);
    var stream = server.accept(io) catch return;
    stream.close(io);
}

test "raceConnect: succeeds against a real local listener" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server_future = io.async(testListener, .{ io, 37101 });
    (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }).sleep(io) catch {};

    const addr = try net.IpAddress.parse("127.0.0.1", 37101);
    var stream = try raceConnect(io, &.{addr}, 3);
    stream.close(io);
    server_future.await(io);
}

test "raceConnect: picks the working candidate when another is refused" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server_future = io.async(testListener, .{ io, 37102 });
    (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }).sleep(io) catch {};

    // Port 37103 has no listener -- a real, fast "connection refused" on
    // loopback, racing alongside the real working one.
    const bad = try net.IpAddress.parse("127.0.0.1", 37103);
    const good = try net.IpAddress.parse("127.0.0.1", 37102);
    var stream = try raceConnect(io, &.{ bad, good }, 3);
    stream.close(io);
    server_future.await(io);
}

test "raceConnect: bounded by timeout against a real unreachable address" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // RFC 5737 TEST-NET-1 -- packets are silently dropped, not refused, so
    // this genuinely exercises the timeout path rather than a fast refusal.
    const addr = try net.IpAddress.parse("192.0.2.1", 9993);
    const t0 = Io.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Timeout, raceConnect(io, &.{addr}, 2));
    const t1 = Io.Timestamp.now(io, .awake);
    try std.testing.expect(t0.durationTo(t1).toMilliseconds() < 2500);
}

test "connectFiltered: a loopback-resolving hostname is rejected -- the real SSRF protection, end to end" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // No listener needed at all -- 127.0.0.1 must never reach the connect
    // step in the first place.
    try std.testing.expectError(error.NoAllowedAddress, connectFiltered(io, "127.0.0.1", 12345, 3));
}

test "connectFiltered: an unresolvable hostname surfaces a real lookup error" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try std.testing.expectError(
        error.UnknownHostName,
        connectFiltered(io, "this-domain-does-not-exist-natyv-test.invalid", 80, 3),
    );
}
