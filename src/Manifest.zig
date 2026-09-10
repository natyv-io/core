//! Builds an Extism plugin manifest JSON blob. Generalized from the
//! bookstore prototype's hand-rolled version -- mirrors the real schema
//! verified directly against Extism's Rust manifest source
//! (`manifest/src/lib.rs`): `allowed_hosts: Option<Vec<String>>`, where
//! `null`/absent means "all hosts allowed" and an explicit (possibly empty)
//! array is the actual security boundary. `null` here maps to omitting the
//! key entirely, matching that semantics exactly rather than picking an
//! arbitrary default.

const std = @import("std");
const json_util = @import("json_util.zig");

const Self = @This();

/// `null` = omit from the manifest (Extism default: all hosts allowed).
/// A slice (including an empty one) = exactly those hosts allowed, nothing
/// else -- the real per-app network security boundary.
allowed_hosts: ?[]const []const u8 = null,
/// Hard per-dispatch deadline Extism's own Wasmtime runtime enforces
/// internally -- exceeding it doesn't return a clean error, it forcibly
/// terminates the WASM call mid-execution, potentially leaving the guest
/// instance's own state (whatever it had mutated so far) inconsistent.
/// Bumped 2026-09-07, 8000 -> 20000 -- real, live-reproduced failure:
/// `mail_client.go`'s own `withIMAPRetry` (a real network attempt, then a
/// reconnect, then a retry attempt -- up to two full IMAP round trips in
/// one dispatch) can legitimately need more than 8s under real-world
/// network slowness, and hitting this ceiling mid-retry produced exactly
/// the "content torn down but never rebuilt, further retries don't help"
/// symptom a mid-flight kill would predict -- not a memory-reclamation or
/// recycle-mechanism bug, this timeout predates that arc entirely. 20000ms
/// gives real reconnect+retry sequences comfortable room while still
/// failing well short of feeling permanently hung to a user.
timeout_ms: u64 = 20000,

pub fn build(self: Self, allocator: std.mem.Allocator, wasm: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64_buf = try allocator.alloc(u8, encoder.calcSize(wasm.len));
    defer allocator.free(b64_buf);
    _ = encoder.encode(b64_buf, wasm);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"wasm\":[{\"data\":\"");
    try out.appendSlice(allocator, b64_buf);
    try out.appendSlice(allocator, "\"}]");

    if (self.allowed_hosts) |hosts| {
        try out.appendSlice(allocator, ",\"allowed_hosts\":[");
        for (hosts, 0..) |host, i| {
            if (i != 0) try out.append(allocator, ',');
            try json_util.writeString(&out, allocator, host);
        }
        try out.append(allocator, ']');
    }

    try out.print(allocator, ",\"timeout_ms\":{d}}}", .{self.timeout_ms});
    return out.toOwnedSlice(allocator);
}

test "omits allowed_hosts when null (all hosts allowed)" {
    const allocator = std.testing.allocator;
    const m: Self = .{};
    const json = try m.build(allocator, "ab");
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "allowed_hosts") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timeout_ms\":20000") != null);
}

test "includes an explicit (possibly empty) allowed_hosts list" {
    const allocator = std.testing.allocator;

    const disallow_all: Self = .{ .allowed_hosts = &.{} };
    const json1 = try disallow_all.build(allocator, "ab");
    defer allocator.free(json1);
    try std.testing.expect(std.mem.indexOf(u8, json1, "\"allowed_hosts\":[]") != null);

    const one_host: Self = .{ .allowed_hosts = &[_][]const u8{"www.google.com"} };
    const json2 = try one_host.build(allocator, "ab");
    defer allocator.free(json2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"allowed_hosts\":[\"www.google.com\"]") != null);
}
