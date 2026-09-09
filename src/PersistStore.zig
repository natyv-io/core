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

allocator: std.mem.Allocator,
/// Owned keys and values (both duped into host memory on insert) -- the
/// real, currently-live persisted state.
store: std.StringHashMapUnmanaged([]u8) = .empty,
/// Owned keys only. A key present here was explicitly freed and must not
/// be recreated by `getOrInit` until an explicit `setValue` clears it.
freed: std.StringHashMapUnmanaged(void) = .empty,

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
pub fn getOrInit(self: *Self, key: []const u8, default: []const u8) !GetOrInitResult {
    if (self.freed.contains(key)) return .freed;
    if (self.store.get(key)) |existing| return .{ .value = existing };
    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    const owned_default = try self.allocator.dupe(u8, default);
    errdefer self.allocator.free(owned_default);
    try self.store.put(self.allocator, owned_key, owned_default);
    return .{ .value = owned_default };
}

/// Unconditional upsert -- creates `key` if absent, overwrites if present,
/// and clears any freed marker (an explicit Set always wins over a prior
/// Free, matching the Go SDK's `Set`/`Reset` contract).
pub fn setValue(self: *Self, key: []const u8, value: []const u8) !void {
    if (self.freed.fetchRemove(key)) |kv| {
        self.allocator.free(kv.key);
    }
    const owned_value = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(owned_value);
    const gop = try self.store.getOrPut(self.allocator, key);
    if (gop.found_existing) {
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
    }
    gop.value_ptr.* = owned_value;
}

/// Removes `key` from the value store and marks it freed -- free-if-absent
/// is a clean no-op success, not an error, matching a plain delete's usual
/// semantics.
pub fn freeKey(self: *Self, key: []const u8) !void {
    if (self.store.fetchRemove(key)) |kv| {
        self.allocator.free(kv.key);
        self.allocator.free(kv.value);
    }
    if (self.freed.contains(key)) return;
    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    try self.freed.put(self.allocator, owned_key, {});
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
