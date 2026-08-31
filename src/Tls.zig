//! Real TLS client wrapper over the vendored mbedTLS library -- the missing
//! piece for `.implicit` connections (IMAPS-style, TLS immediately on
//! connect) and `tcp_upgrade_tls` (STARTTLS, upgrading an already-connected
//! plaintext stream in place). See the `natyv-tcp-tls-host-function` memory
//! for the full design.
//!
//! Deliberately its own file/`@cImport` boundary, not folded into the
//! shared `c.zig` -- same reasoning as `MbedtlsSmokeTest.zig`'s own doc
//! comment.
//!
//! CA trust: bundles Mozilla's CA root store (`src/assets/cacert.pem`, the
//! same one curl ships) as the default. A dev-supplied `custom_ca_pem`
//! (from `conf.natyv.json`'s `allowed_sockets[].ca_cert_path`) *replaces*
//! the default trust set for that one endpoint rather than adding to it --
//! a private/internal CA shouldn't also leave every public CA trusted for
//! what's meant to be a locked-down connection.
//!
//! Reuses the stream's `Reader`/`Writer` with the same zero-length-buffer
//! design already verified for plain `tcp_read`/`tcp_write` (see
//! `TcpRegistry.zig`'s own doc comment) -- mbedTLS's BIO callbacks bridge
//! straight to `readVec`/`writeAll`, no separate raw-syscall path needed.

const std = @import("std");
const Io = std.Io;
const net = Io.net;

const c = @cImport({
    @cInclude("mbedtls/ssl.h");
    @cInclude("mbedtls/entropy.h");
    @cInclude("mbedtls/ctr_drbg.h");
    @cInclude("mbedtls/x509_crt.h");
    @cInclude("mbedtls/error.h");
});

const default_ca_bundle = @embedFile("assets/cacert.pem");

pub const Error = error{
    TlsInitFailed,
    TlsCaLoadFailed,
    TlsHandshakeFailed,
    TlsReadFailed,
    TlsWriteFailed,
};

const write_buf_len = 4096;

pub const Session = struct {
    entropy: c.mbedtls_entropy_context,
    ctr_drbg: c.mbedtls_ctr_drbg_context,
    ca_chain: c.mbedtls_x509_crt,
    conf: c.mbedtls_ssl_config,
    ssl: c.mbedtls_ssl_context,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    write_buf: [write_buf_len]u8 = undefined,

    /// Constructs `self` in place -- deliberately an out-parameter, not a
    /// return-by-value, because `mbedtls_ssl_set_bio` below hands mbedTLS a
    /// raw `*Session` context pointer for its `bioSend`/`bioRecv`
    /// callbacks. That pointer has to be this session's real, final,
    /// never-moving-again address from the moment it's captured -- a
    /// return-by-value `Session` (as this function used to be) captures the
    /// address of its own *local* stack variable instead, which is only
    /// valid until the function returns; any copy the caller then makes
    /// storing the result (`conn.tls_session = handshake(...)`) leaves
    /// mbedTLS's internal BIO context dangling at that dead stack frame.
    /// This was a real, hard-to-see bug: the stale pointer happened to
    /// still read back correctly for the handshake itself and one
    /// subsequent `read()` (the dead stack memory hadn't been overwritten
    /// yet), then segfaulted inside `close()`'s `bioSend` once enough other
    /// calls had reused that stack region -- caught only by a real
    /// end-to-end guest run through the Go SDK, not by this file's own
    /// standalone tests (which construct `session` as a local that's never
    /// moved afterward, so the bug could never manifest there). Callers
    /// must place `self` at its real final address *before* calling this
    /// (a local `var`, or `&optional_field.?` once the field is non-null)
    /// and never move it again afterward.
    ///
    /// `hostname` must be valid for the duration of this call (mbedTLS
    /// copies what it needs internally during `mbedtls_ssl_set_hostname`,
    /// so it doesn't need to outlive the call itself, just be valid at call
    /// time). `custom_ca_pem`, if non-null, *replaces* the bundled default
    /// trust set -- see the file doc comment. `custom_ca_pem` must be
    /// NUL-terminated with the NUL included in its length (mbedTLS's own
    /// PEM-parsing convention) -- callers loading a dev-supplied file are
    /// responsible for that; the bundled default already satisfies it via
    /// `@embedFile`'s own sentinel-terminated array.
    pub fn handshake(self: *Session, stream: net.Stream, io: Io, hostname: [:0]const u8, custom_ca_pem: ?[:0]const u8) Error!void {
        self.* = .{
            .entropy = undefined,
            .ctr_drbg = undefined,
            .ca_chain = undefined,
            .conf = undefined,
            .ssl = undefined,
            .reader = stream.reader(io, &.{}),
            .writer = undefined,
        };
        self.writer = stream.writer(io, &self.write_buf);

        c.mbedtls_entropy_init(&self.entropy);
        c.mbedtls_ctr_drbg_init(&self.ctr_drbg);
        c.mbedtls_x509_crt_init(&self.ca_chain);
        c.mbedtls_ssl_config_init(&self.conf);
        c.mbedtls_ssl_init(&self.ssl);
        errdefer self.deinit();

        const pers = "natyv-tls";
        if (c.mbedtls_ctr_drbg_seed(&self.ctr_drbg, c.mbedtls_entropy_func, &self.entropy, pers, pers.len) != 0) {
            return error.TlsInitFailed;
        }

        const ca_pem: [:0]const u8 = custom_ca_pem orelse default_ca_bundle;
        if (c.mbedtls_x509_crt_parse(&self.ca_chain, ca_pem.ptr, ca_pem.len + 1) != 0) {
            return error.TlsCaLoadFailed;
        }

        if (c.mbedtls_ssl_config_defaults(&self.conf, c.MBEDTLS_SSL_IS_CLIENT, c.MBEDTLS_SSL_TRANSPORT_STREAM, c.MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
            return error.TlsInitFailed;
        }
        c.mbedtls_ssl_conf_authmode(&self.conf, c.MBEDTLS_SSL_VERIFY_REQUIRED);
        c.mbedtls_ssl_conf_ca_chain(&self.conf, &self.ca_chain, null);
        c.mbedtls_ssl_conf_rng(&self.conf, c.mbedtls_ctr_drbg_random, &self.ctr_drbg);

        if (c.mbedtls_ssl_setup(&self.ssl, &self.conf) != 0) {
            return error.TlsInitFailed;
        }
        if (c.mbedtls_ssl_set_hostname(&self.ssl, hostname.ptr) != 0) {
            return error.TlsInitFailed;
        }
        c.mbedtls_ssl_set_bio(&self.ssl, self, bioSend, bioRecv, null);

        while (true) {
            const ret = c.mbedtls_ssl_handshake(&self.ssl);
            if (ret == 0) break;
            if (ret != c.MBEDTLS_ERR_SSL_WANT_READ and ret != c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                return error.TlsHandshakeFailed;
            }
        }
    }

    pub fn read(self: *Session, buf: []u8) Error!usize {
        while (true) {
            const ret = c.mbedtls_ssl_read(&self.ssl, buf.ptr, buf.len);
            if (ret == c.MBEDTLS_ERR_SSL_WANT_READ or ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (ret == 0 or ret == c.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
            if (ret < 0) return error.TlsReadFailed;
            return @intCast(ret);
        }
    }

    pub fn write(self: *Session, buf: []const u8) Error!void {
        var sent: usize = 0;
        while (sent < buf.len) {
            const ret = c.mbedtls_ssl_write(&self.ssl, buf.ptr + sent, buf.len - sent);
            if (ret == c.MBEDTLS_ERR_SSL_WANT_READ or ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (ret < 0) return error.TlsWriteFailed;
            sent += @intCast(ret);
        }
    }

    pub fn close(self: *Session) void {
        _ = c.mbedtls_ssl_close_notify(&self.ssl);
        self.deinit();
    }

    fn deinit(self: *Session) void {
        c.mbedtls_ssl_free(&self.ssl);
        c.mbedtls_ssl_config_free(&self.conf);
        c.mbedtls_x509_crt_free(&self.ca_chain);
        c.mbedtls_ctr_drbg_free(&self.ctr_drbg);
        c.mbedtls_entropy_free(&self.entropy);
    }

    fn bioSend(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
        const session: *Session = @ptrCast(@alignCast(ctx.?));
        session.writer.interface.writeAll(buf[0..len]) catch return c.MBEDTLS_ERR_SSL_INTERNAL_ERROR;
        session.writer.interface.flush() catch return c.MBEDTLS_ERR_SSL_INTERNAL_ERROR;
        return @intCast(len);
    }

    fn bioRecv(ctx: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) c_int {
        const session: *Session = @ptrCast(@alignCast(ctx.?));
        if (len == 0) return 0;
        var data: [1][]u8 = .{buf[0..len]};
        const n = session.reader.interface.readVec(&data) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return c.MBEDTLS_ERR_SSL_INTERNAL_ERROR,
        };
        return @intCast(n);
    }
};

// --- Tests: real handshakes against real public servers. This is a
// genuinely new category of test for this project -- proving certificate
// verification actually works (both accepting a real trusted cert and
// rejecting a bad one) needs a real CA-signed server and a real
// known-broken one respectively; there's no loopback-only way to prove
// this the way TcpRegistry.zig/Tcp.zig's own tests could stay
// internet-free. Needs live internet to run. ---

fn testPlainConnect(io: Io, host: [:0]const u8, port: u16) !net.Stream {
    const host_name = try net.HostName.init(host);
    return host_name.connect(io, port, .{ .mode = .stream });
}

test "handshake: real TLS to imap.gmail.com:993, reads the real IMAP greeting" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try testPlainConnect(io, "imap.gmail.com", 993);
    var session: Session = undefined;
    try session.handshake(stream, io, "imap.gmail.com", null);
    defer session.close();

    var buf: [256]u8 = undefined;
    const n = try session.read(&buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.startsWith(u8, buf[0..n], "* OK"));
}

test "handshake: a real self-signed cert is correctly rejected, not silently accepted" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try testPlainConnect(io, "self-signed.badssl.com", 443);
    var session: Session = undefined;
    try std.testing.expectError(error.TlsHandshakeFailed, session.handshake(stream, io, "self-signed.badssl.com", null));
}

test "handshake: a real cert for the wrong hostname is correctly rejected" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stream = try testPlainConnect(io, "wrong.host.badssl.com", 443);
    var session: Session = undefined;
    try std.testing.expectError(error.TlsHandshakeFailed, session.handshake(stream, io, "wrong.host.badssl.com", null));
}
