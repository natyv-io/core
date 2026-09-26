//! The real, pure logic backing host-owned persisted state
//! (`capabilities/Persist.zig`'s host-fn glue calls straight into this) --
//! a plain, allocator-owned key/value store plus a separate freed-keys set.
//! Deliberately dependency-free (no `c.zig`, no `host_fn_util.zig`) so it
//! gets its own clean, standalone test root with no C-import/module-root
//! entanglement at all -- `capabilities/Persist.zig` itself lives one
//! directory down and needs `../c.zig`/`../host_fn_util.zig`, which is fine
//! when it's compiled as part of the larger `core-src` module graph (its
//! real, only production use) but hits Zig's real "import of file outside
//! module path" error the moment it's made its *own* standalone test root
//! -- the same constraint this project already hit once during the binding
//! generator arc. Splitting the pure logic out here, matching how
//! `DrawBatcher.zig`/`TcpRegistry.zig`/etc. already live directly in `src/`
//! specifically so they can have their own clean test roots, sidesteps it
//! entirely rather than duplicating the C-import boundary the way the
//! bindgen arc's `BindingsC.zig`/`BindingsHostFnUtil.zig` had to.
//!
//! See `capabilities/Persist.zig`'s own doc comment for the full design
//! (why host-owned state exists, the wire contract, the "freed" third
//! state's own rationale) -- not repeated here.

const std = @import("std");

const Self = @This();

/// Persisted values live host-side, outside the guest's Extism-bounded wasm
/// memory, and deliberately survive instance recycling -- so without these a
/// guest looping `natyv_persist_set` (or `_free`, which also stores a key)
/// with unique keys grows host memory without limit, and recycling can't
/// reclaim it. Both maps count against both caps. Sized far above any real
/// `Persisted[T]` use (a handful of small UI-state values per app).
pub const max_entries = 4096;
pub const max_total_bytes = 16 * 1024 * 1024;

pub const Error = error{ LimitExceeded, OutOfMemory };

allocator: std.mem.Allocator,
/// Owned keys and values (both duped into host memory on insert) -- the
/// real, currently-live persisted state.
store: std.StringHashMapUnmanaged([]u8) = .empty,
/// Owned keys only. A key present here was explicitly freed and must not
/// be recreated by `getOrInit` until an explicit `setValue` clears it.
freed: std.StringHashMapUnmanaged(void) = .empty,
/// Sum of every owned key and value length across `store` and `freed`.
total_bytes: usize = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    var store_it = self.store.iterator();
    while (store_it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.store.deinit(self.allocator);
    var freed_it = self.freed.keyIterator();
    while (freed_it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.freed.deinit(self.allocator);
}

pub const GetOrInitResult = union(enum) {
    /// Borrowed from `self.store` -- valid only until the next mutation of
    /// this key. Callers must copy out anything they need to keep past
    /// that point.
    value: []const u8,
    freed: void,
};

/// Returns the resolved value for `key`: the existing one if present, or
/// `default` (duped into the store) if `key` has never been seen. A freed
/// key stays freed -- never silently recreated here.
pub fn getOrInit(self: *Self, key: []const u8, default: []const u8) Error!GetOrInitResult {
    if (self.freed.contains(key)) return .freed;
    if (self.store.get(key)) |existing| return .{ .value = existing };
    try self.checkRoom(1, key.len + default.len, 0);
    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    const owned_default = try self.allocator.dupe(u8, default);
    errdefer self.allocator.free(owned_default);
    try self.store.put(self.allocator, owned_key, owned_default);
    self.total_bytes += key.len + default.len;
    return .{ .value = owned_default };
}

/// Unconditional upsert -- creates `key` if absent, overwrites if present,
/// and clears any freed marker (an explicit Set always wins over a prior
/// Free, matching the Go SDK's `Set`/`Reset` contract).
pub fn setValue(self: *Self, key: []const u8, value: []const u8) Error!void {
    // A freed key's bytes are already counted and just move maps; only a
    // brand-new key adds an entry and its own key bytes.
    if (self.store.get(key)) |old| {
        try self.checkRoom(0, value.len, old.len);
    } else if (self.freed.contains(key)) {
        try self.checkRoom(0, value.len, 0);
    } else {
        try self.checkRoom(1, key.len + value.len, 0);
    }
    if (self.freed.fetchRemove(key)) |kv| {
        self.allocator.free(kv.key);
        self.total_bytes -= key.len;
    }
    const owned_value = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(owned_value);
    const gop = try self.store.getOrPut(self.allocator, key);
    if (gop.found_existing) {
        self.total_bytes -= gop.value_ptr.len;
        self.allocator.free(gop.value_ptr.*);
    } else {
        // `getOrPut` stores the caller's own `key` slice on a fresh entry --
        // overwrite immediately with a real owned copy, or the map would
        // hold a dangling reference into the guest-request buffer the
        // host-fn glue frees right after this call returns.
        gop.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
            // Leave the map's own bookkeeping consistent: undo the just-created
            // (still key-less) slot rather than leaving a broken entry behind.
            _ = self.store.remove(key);
            return err;
        };
        self.total_bytes += key.len;
    }
    gop.value_ptr.* = owned_value;
    self.total_bytes += value.len;
}

/// Removes `key` from the value store and marks it freed -- free-if-absent
/// is a clean no-op success, not an error, matching a plain delete's usual
/// semantics.
pub fn freeKey(self: *Self, key: []const u8) Error!void {
    if (self.freed.contains(key)) return;
    if (!self.store.contains(key)) try self.checkRoom(1, key.len, 0);
    if (self.store.fetchRemove(key)) |kv| {
        self.total_bytes -= kv.key.len + kv.value.len;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value);
    }
    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    try self.freed.put(self.allocator, owned_key, {});
    self.total_bytes += key.len;
}

/// Rejects a mutation that would add `new_entries` entries and `add_bytes`
/// bytes while releasing `release_bytes` -- checked before anything is
/// touched, so a rejected call leaves the store exactly as it was.
fn checkRoom(self: *const Self, new_entries: usize, add_bytes: usize, release_bytes: usize) Error!void {
    if (self.store.count() + self.freed.count() + new_entries > max_entries) return error.LimitExceeded;
    if (self.total_bytes - release_bytes + add_bytes > max_total_bytes) return error.LimitExceeded;
}

/// Appends `s` into `out` as an escaped JSON string *body* (no surrounding
/// quotes -- callers wrap those themselves). Hand-rolled rather than
/// reaching for `std.json.Stringify` against an `ArrayList`-backed writer,
/// so this has no dependency on that API's exact writer-adapter shape --
/// small, self-contained, and directly testable, matching this arc's own
/// `persistjson` precedent (SDK-side) of a small hand-rolled encoder over a
/// stdlib dependency for exactly this kind of narrow, closed-set need.
pub fn appendJsonEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            // All control characters (0x00-0x1f, including \n/\r/\t) go
            // through the generic \u00XX form -- still ordinary, valid JSON,
            // and simpler than carving the three short-escape cases out of
            // this range (Zig's switch rejects overlapping case values, and
            // this wire format is machine-to-machine, never hand-read).
            0...0x1f => {
                var esc_buf: [6]u8 = undefined;
                const esc = std.fmt.bufPrint(&esc_buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                try out.appendSlice(allocator, esc);
            },
            else => try out.append(allocator, ch),
        }
    }
}

test "getOrInit: fresh key stores and returns the default" {
    const allocator = std.testing.allocator;
    var self = Self.init(allocator);
    defer self.deinit();

    const result = try self.getOrInit("x", "\"Inbox\"");
    try std.testing.expectEqualStrings("\"Inbox\"", result.value);
    // Confirmed actually stored, not just returned:
    try std.testing.expectEqualStrings("\"Inbox\"", self.store.get("x").?);
}

test "getOrInit: existing key returns the existing value, ignoring a new default" {
    const allocator = std.testing.allocator;
    var self = Self.init(allocator);
    defer self.deinit();

    _ = try self.getOrInit("x", "\"Inbox\"");
    const result = try self.getOrInit("x", "\"SomethingElse\"");
    try std.testing.expectEqualStrings("\"Inbox\"", result.value);
}

test "setValue: creates when absent, overwrites when present, clears a freed marker" {
    const allocator = std.testing.allocator;
    var self = Self.init(allocator);
    defer self.deinit();

    try self.setValue("x", "\"a\"");
    try std.testing.expectEqualStrings("\"a\"", self.store.get("x").?);

    try self.setValue("x", "\"b\"");
    try std.testing.expectEqualStrings("\"b\"", self.store.get("x").?);

    try self.freeKey("x");
    try std.testing.expect(self.freed.contains("x"));
    try self.setValue("x", "\"c\"");
    try std.testing.expect(!self.freed.contains("x"));
    try std.testing.expectEqualStrings("\"c\"", self.store.get("x").?);
}

test "freeKey: removes from the store and marks freed; a subsequent getOrInit does not recreate it" {
    const allocator = std.testing.allocator;
    var self = Self.init(allocator);
    defer self.deinit();

    _ = try self.getOrInit("x", "\"Inbox\"");
    try self.freeKey("x");
    try std.testing.expect(self.store.get("x") == null);

    const result = try self.getOrInit("x", "\"Inbox\"");
    try std.testing.expect(result == .freed);
    try std.testing.expect(self.store.get("x") == null);
}

test "freeKey: on an absent key is a clean no-op" {
    const allocator = std.testing.allocator;
    var self = Self.init(allocator);
    defer self.deinit();

    try self.freeKey("never-seen");
    try std.testing.expect(self.freed.contains("never-seen"));
}

test "multiple keys don't interfere with each other" {
    const allocator = std.testing.allocator;
    var self = Self.init(allocator);
    defer self.deinit();

    _ = try self.getOrInit("a", "1");
    _ = try self.getOrInit("b", "2");
    try self.freeKey("a");

    const a_result = try self.getOrInit("a", "1");
    try std.testing.expect(a_result == .freed);
    const b_result = try self.getOrInit("b", "999");
    try std.testing.expectEqualStrings("2", b_result.value);
}

test "appendJsonEscaped: quotes, backslashes, and control characters are all escaped" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    // Input bytes: say "hi" \ n <TAB> end -- the `\n` here is a literal
    // backslash followed by the letter n, not a newline; the real control
    // character is the actual tab right after it.
    try appendJsonEscaped(&out, allocator, "say \"hi\"\\n\tend");
    // Quotes/backslash get short escapes; the real tab gets the generic
    // \u00XX form (see appendJsonEscaped's own doc comment for why \n/\r/\t
    // aren't special-cased).
    try std.testing.expectEqualStrings("say \\\"hi\\\"\\\\n\\u0009end", out.items);
}

test "caps: entry count and total bytes are enforced, and a rejected call changes nothing" {
    const allocator = std.testing.allocator;
    var self = Self.init(allocator);
    defer self.deinit();

    var key_buf: [16]u8 = undefined;
    for (0..max_entries) |i| {
        const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        if (i % 2 == 0) try self.setValue(key, "1") else try self.freeKey(key);
    }
    try std.testing.expectError(error.LimitExceeded, self.setValue("one-more", "1"));
    try std.testing.expectError(error.LimitExceeded, self.freeKey("one-more"));
    try std.testing.expectError(error.LimitExceeded, self.getOrInit("one-more", "1"));
    // Existing keys still work at the entry cap: overwrite, free, revive.
    try self.setValue("k0", "2");
    try self.freeKey("k0");
    try self.setValue("k1", "3");
    try std.testing.expectEqualStrings("3", self.store.get("k1").?);

    const bytes_before = self.total_bytes;
    const big = try allocator.alloc(u8, max_total_bytes);
    defer allocator.free(big);
    @memset(big, 'x');
    try std.testing.expectError(error.LimitExceeded, self.setValue("k2", big));
    try std.testing.expectEqualStrings("1", self.store.get("k2").?);
    try std.testing.expectEqual(bytes_before, self.total_bytes);
}

test "total_bytes tracks every mutation and returns to zero" {
    const allocator = std.testing.allocator;
    var self = Self.init(allocator);
    defer self.deinit();

    _ = try self.getOrInit("ab", "123");
    try std.testing.expectEqual(@as(usize, 5), self.total_bytes);
    try self.setValue("ab", "1");
    try std.testing.expectEqual(@as(usize, 3), self.total_bytes);
    try self.freeKey("ab");
    try std.testing.expectEqual(@as(usize, 2), self.total_bytes);
    try self.setValue("ab", "12");
    try std.testing.expectEqual(@as(usize, 4), self.total_bytes);
    try self.setValue("c", "");
    try std.testing.expectEqual(@as(usize, 5), self.total_bytes);
}
