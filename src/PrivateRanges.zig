//! Classifies IP addresses as private/reserved -- the real security boundary
//! for the planned TCP/TLS host function's SSRF mitigation (see the
//! `natyv-dns-resolution-footguns` memory): once a hostname resolves, the
//! resolved address must be checked here *before* connecting, since an
//! allowlisted hostname's DNS answer can point anywhere regardless of what
//! the dev intended (DNS rebinding).
//!
//! Ranges sourced directly from IANA's own registries, not guessed:
//! https://www.iana.org/assignments/iana-ipv4-special-registry/
//! https://www.iana.org/assignments/iana-ipv6-special-registry/
//!
//! Deliberately a hand-rolled, well-tested table rather than a third-party
//! dependency or a live fetch from IANA at runtime -- this data is small and
//! stable (changes on the order of years, not days), and fetching it live
//! would mean using the same untrusted network path this check exists to
//! defend against just to learn what to defend against.

const std = @import("std");
const net = std.Io.net;

const Cidr = struct {
    prefix: []const u8,
    bits: u8,
};

const ipv4_reserved = [_]Cidr{
    .{ .prefix = &[_]u8{ 0, 0, 0, 0 }, .bits = 8 }, // "this network"
    .{ .prefix = &[_]u8{ 10, 0, 0, 0 }, .bits = 8 }, // RFC 1918 private
    .{ .prefix = &[_]u8{ 100, 64, 0, 0 }, .bits = 10 }, // carrier-grade NAT
    .{ .prefix = &[_]u8{ 127, 0, 0, 0 }, .bits = 8 }, // loopback
    .{ .prefix = &[_]u8{ 169, 254, 0, 0 }, .bits = 16 }, // link-local, incl. cloud metadata 169.254.169.254
    .{ .prefix = &[_]u8{ 172, 16, 0, 0 }, .bits = 12 }, // RFC 1918 private
    .{ .prefix = &[_]u8{ 192, 0, 0, 0 }, .bits = 24 }, // IETF protocol assignments
    .{ .prefix = &[_]u8{ 192, 0, 2, 0 }, .bits = 24 }, // TEST-NET-1 (documentation)
    .{ .prefix = &[_]u8{ 192, 168, 0, 0 }, .bits = 16 }, // RFC 1918 private
    .{ .prefix = &[_]u8{ 198, 18, 0, 0 }, .bits = 15 }, // benchmarking
    .{ .prefix = &[_]u8{ 198, 51, 100, 0 }, .bits = 24 }, // TEST-NET-2 (documentation)
    .{ .prefix = &[_]u8{ 203, 0, 113, 0 }, .bits = 24 }, // TEST-NET-3 (documentation)
    .{ .prefix = &[_]u8{ 224, 0, 0, 0 }, .bits = 4 }, // multicast
    .{ .prefix = &[_]u8{ 240, 0, 0, 0 }, .bits = 4 }, // reserved for future use
    .{ .prefix = &[_]u8{ 255, 255, 255, 255 }, .bits = 32 }, // limited broadcast
};

const ipv6_reserved = [_]Cidr{
    .{ .prefix = &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, .bits = 128 }, // ::1, loopback
    .{ .prefix = &[_]u8{0} ** 16, .bits = 128 }, // ::, unspecified
    .{ .prefix = &[_]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{0} ** 8, .bits = 64 }, // 100::/64, discard-only
    .{ .prefix = &[_]u8{ 0x20, 0x01, 0x0d, 0xb8 } ++ [_]u8{0} ** 12, .bits = 32 }, // 2001:db8::/32, documentation
    .{ .prefix = &[_]u8{0xfc} ++ [_]u8{0} ** 15, .bits = 7 }, // fc00::/7, Unique Local Addresses
    .{ .prefix = &[_]u8{ 0xfe, 0x80 } ++ [_]u8{0} ** 14, .bits = 10 }, // fe80::/10, link-local
    .{ .prefix = &[_]u8{0xff} ++ [_]u8{0} ** 15, .bits = 8 }, // ff00::/8, multicast
};

// These two forms embed a literal IPv4 address inside an IPv6-looking one --
// `::ffff:169.254.169.254` is the AWS metadata address wearing an IPv6
// costume. They must be unwrapped and the embedded IPv4 re-checked, not
// blocked wholesale (an IPv4-mapped address to a legitimately public IPv4,
// e.g. `::ffff:8.8.8.8`, must stay allowed).
const ipv4_mapped_prefix = [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff };
const nat64_prefix = [_]u8{ 0x00, 0x64, 0xff, 0x9b } ++ [_]u8{0} ** 8;

fn matchesPrefix(addr: []const u8, prefix: []const u8, bits: u8) bool {
    const full_bytes = bits / 8;
    if (!std.mem.eql(u8, addr[0..full_bytes], prefix[0..full_bytes])) return false;
    const rem_bits = bits % 8;
    if (rem_bits == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @intCast(8 - rem_bits);
    return (addr[full_bytes] & mask) == (prefix[full_bytes] & mask);
}

pub fn isReservedIp4(bytes: [4]u8) bool {
    for (ipv4_reserved) |cidr| {
        if (matchesPrefix(&bytes, cidr.prefix, cidr.bits)) return true;
    }
    return false;
}

pub fn isReservedIp6(bytes: [16]u8) bool {
    for (ipv6_reserved) |cidr| {
        if (matchesPrefix(&bytes, cidr.prefix, cidr.bits)) return true;
    }
    if (matchesPrefix(&bytes, &ipv4_mapped_prefix, 96) or matchesPrefix(&bytes, &nat64_prefix, 96)) {
        const embedded: [4]u8 = bytes[12..16].*;
        return isReservedIp4(embedded);
    }
    return false;
}

/// The real entry point `tcp_connect` calls per resolved candidate address,
/// before ever attempting a connection to it.
pub fn isReserved(address: net.IpAddress) bool {
    return switch (address) {
        .ip4 => |a| isReservedIp4(a.bytes),
        .ip6 => |a| isReservedIp6(a.bytes),
    };
}

fn ip4(a: u8, b: u8, c: u8, d: u8) net.IpAddress {
    return .{ .ip4 = .{ .bytes = .{ a, b, c, d }, .port = 0 } };
}

fn ip6(bytes: [16]u8) net.IpAddress {
    return .{ .ip6 = .{ .bytes = bytes, .port = 0 } };
}

test "ipv4: RFC 1918 private ranges, boundaries in and out" {
    try std.testing.expect(isReserved(ip4(10, 0, 0, 0)));
    try std.testing.expect(isReserved(ip4(10, 255, 255, 255)));
    try std.testing.expect(!isReserved(ip4(9, 255, 255, 255)));
    try std.testing.expect(!isReserved(ip4(11, 0, 0, 0)));

    try std.testing.expect(isReserved(ip4(172, 16, 0, 0)));
    try std.testing.expect(isReserved(ip4(172, 31, 255, 255)));
    try std.testing.expect(!isReserved(ip4(172, 15, 255, 255)));
    try std.testing.expect(!isReserved(ip4(172, 32, 0, 0)));

    try std.testing.expect(isReserved(ip4(192, 168, 0, 0)));
    try std.testing.expect(isReserved(ip4(192, 168, 255, 255)));
    try std.testing.expect(!isReserved(ip4(192, 167, 255, 255)));
    try std.testing.expect(!isReserved(ip4(192, 169, 0, 0)));
}

test "ipv4: loopback and link-local, including the cloud metadata address" {
    try std.testing.expect(isReserved(ip4(127, 0, 0, 1)));
    try std.testing.expect(isReserved(ip4(127, 255, 255, 255)));
    try std.testing.expect(!isReserved(ip4(126, 255, 255, 255)));

    try std.testing.expect(isReserved(ip4(169, 254, 0, 0)));
    try std.testing.expect(isReserved(ip4(169, 254, 169, 254))); // AWS/cloud metadata endpoint
    try std.testing.expect(isReserved(ip4(169, 254, 255, 255)));
    try std.testing.expect(!isReserved(ip4(169, 253, 255, 255)));
    try std.testing.expect(!isReserved(ip4(169, 255, 0, 0)));
}

test "ipv4: carrier-grade NAT, benchmarking, documentation, and edge ranges" {
    try std.testing.expect(isReserved(ip4(100, 64, 0, 0)));
    try std.testing.expect(isReserved(ip4(100, 127, 255, 255)));
    try std.testing.expect(!isReserved(ip4(100, 63, 255, 255)));
    try std.testing.expect(!isReserved(ip4(100, 128, 0, 0)));

    try std.testing.expect(isReserved(ip4(198, 18, 0, 0)));
    try std.testing.expect(isReserved(ip4(198, 19, 255, 255)));
    try std.testing.expect(!isReserved(ip4(198, 17, 255, 255)));
    try std.testing.expect(!isReserved(ip4(198, 20, 0, 0)));

    try std.testing.expect(isReserved(ip4(192, 0, 2, 1))); // TEST-NET-1
    try std.testing.expect(isReserved(ip4(198, 51, 100, 5))); // TEST-NET-2
    try std.testing.expect(isReserved(ip4(203, 0, 113, 1))); // TEST-NET-3
    try std.testing.expect(!isReserved(ip4(203, 0, 112, 255)));
    try std.testing.expect(!isReserved(ip4(203, 0, 114, 0)));

    try std.testing.expect(isReserved(ip4(192, 0, 0, 5)));
    try std.testing.expect(!isReserved(ip4(192, 0, 1, 0)));
}

test "ipv4: multicast, future-reserved, and broadcast" {
    try std.testing.expect(isReserved(ip4(224, 0, 0, 1)));
    try std.testing.expect(isReserved(ip4(239, 255, 255, 255)));
    try std.testing.expect(!isReserved(ip4(223, 255, 255, 255)));

    try std.testing.expect(isReserved(ip4(240, 0, 0, 0)));
    try std.testing.expect(isReserved(ip4(255, 255, 255, 254)));
    try std.testing.expect(isReserved(ip4(255, 255, 255, 255)));
}

test "ipv4: known-public addresses stay unreserved" {
    try std.testing.expect(!isReserved(ip4(8, 8, 8, 8))); // public DNS
    try std.testing.expect(!isReserved(ip4(1, 1, 1, 1))); // public DNS
    try std.testing.expect(!isReserved(ip4(142, 250, 0, 100))); // real public range
}

test "ipv6: loopback and unspecified" {
    try std.testing.expect(isReserved(ip6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }))); // ::1
    try std.testing.expect(isReserved(ip6(.{0} ** 16))); // ::
    try std.testing.expect(!isReserved(ip6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 }))); // ::2
}

test "ipv6: discard-only and documentation ranges" {
    try std.testing.expect(isReserved(ip6(.{ 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }))); // 100::ffff
    try std.testing.expect(!isReserved(ip6(.{ 0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }))); // 101::

    try std.testing.expect(isReserved(ip6(.{ 0x20, 0x01, 0x0d, 0xb8, 0x12, 0x34 } ++ .{0} ** 10))); // 2001:db8:1234::
    try std.testing.expect(!isReserved(ip6(.{ 0x20, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }))); // 2002::
}

test "ipv6: unique local (fc00::/7, not the deprecated fec0::/10 site-local) and link-local" {
    try std.testing.expect(isReserved(ip6(.{0xfc} ++ .{0} ** 15))); // fc00::
    try std.testing.expect(isReserved(ip6(.{0xfd} ++ .{0xff} ** 15))); // fdff:ffff:... (last of /7)
    try std.testing.expect(!isReserved(ip6(.{0xfb} ++ .{0xff} ** 15))); // fbff:... (just below the range)

    try std.testing.expect(isReserved(ip6(.{ 0xfe, 0x80 } ++ .{0} ** 14))); // fe80::
    try std.testing.expect(isReserved(ip6(.{ 0xfe, 0xbf } ++ .{0xff} ** 14))); // febf:ffff:... (last of /10)
    try std.testing.expect(!isReserved(ip6(.{ 0xfe, 0x00 } ++ .{0} ** 14))); // fe00:: (below fe80::/10)
    try std.testing.expect(!isReserved(ip6(.{ 0xfe, 0xc0 } ++ .{0} ** 14))); // fec0:: (deprecated site-local, deliberately not blocked)
}

test "ipv6: multicast" {
    try std.testing.expect(isReserved(ip6(.{0xff} ++ .{0} ** 15))); // ff00::
    try std.testing.expect(isReserved(ip6(.{ 0xff, 0x02 } ++ .{0} ** 13 ++ .{1}))); // ff02::1
    try std.testing.expect(!isReserved(ip6(.{ 0xfe, 0xff } ++ .{0xff} ** 14))); // feff:... (just below ff00::/8)
}

test "ipv6: IPv4-mapped and NAT64 forms unwrap the embedded IPv4, not blocked wholesale" {
    // ::ffff:169.254.169.254 -- cloud metadata address wearing an IPv6 costume.
    try std.testing.expect(isReserved(ip6(.{0} ** 10 ++ .{ 0xff, 0xff, 169, 254, 169, 254 })));
    // ::ffff:8.8.8.8 -- a legitimately public IPv4-mapped address must stay allowed.
    try std.testing.expect(!isReserved(ip6(.{0} ** 10 ++ .{ 0xff, 0xff, 8, 8, 8, 8 })));

    // 64:ff9b::169.254.169.254 -- same bypass via NAT64 instead of IPv4-mapped.
    try std.testing.expect(isReserved(ip6(.{ 0x00, 0x64, 0xff, 0x9b } ++ .{0} ** 8 ++ .{ 169, 254, 169, 254 })));
    // 64:ff9b::8.8.8.8 -- must stay allowed.
    try std.testing.expect(!isReserved(ip6(.{ 0x00, 0x64, 0xff, 0x9b } ++ .{0} ** 8 ++ .{ 8, 8, 8, 8 })));
}
