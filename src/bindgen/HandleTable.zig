//! Shared infra generated host trampolines call into for opaque-handle
//! marshaling -- a real C pointer (e.g. `fixture_create`'s returned
//! `FixtureHandle*`) lives in the host's own address space and can never be
//! handed directly to a wasm guest, so every opaque handle crossing the
//! Extism boundary is really a small `u32` id into one of these tables,
//! the same "id, not a raw pointer" shape `WidgetHost.zig`'s own slot
//! registry already uses for widget ids.
//!
//! Fixed capacity, not an unbounded map -- matches this project's own
//! memory-efficiency discipline (see project memory
//! `feedback_natyv_memory_efficiency`): a dev binding a library gets a
//! bounded number of live handles per type, same as natyv's own
//! `max_widgets` cap, rather than letting a forgotten `fixture_destroy`
//! call grow this without limit.
const std = @import("std");

pub fn HandleTable(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        entries: [capacity]?*T = @splat(null),

        /// Returns `null` when the table is full -- a generated trampoline
        /// surfaces this as a real, visible `{"error":"..."}` response,
        /// never a silent overwrite of an existing id.
        pub fn insert(self: *Self, ptr: *T) ?u32 {
            for (&self.entries, 0..) |*slot, i| {
                if (slot.* == null) {
                    slot.* = ptr;
                    return @intCast(i);
                }
            }
            return null;
        }

        pub fn get(self: *Self, id: u32) ?*T {
            if (id >= capacity) return null;
            return self.entries[id];
        }

        pub fn remove(self: *Self, id: u32) void {
            if (id >= capacity) return;
            self.entries[id] = null;
        }
    };
}

const Dummy = struct { value: i32 = 0 };

test "insert returns increasing ids, get resolves them back to the same pointer" {
    var table = HandleTable(Dummy, 4){};
    var a = Dummy{ .value = 1 };
    var b = Dummy{ .value = 2 };
    const id_a = table.insert(&a).?;
    const id_b = table.insert(&b).?;
    try std.testing.expect(id_a != id_b);
    try std.testing.expectEqual(@as(i32, 1), table.get(id_a).?.value);
    try std.testing.expectEqual(@as(i32, 2), table.get(id_b).?.value);
}

test "remove frees the slot for reuse, get returns null after removal" {
    var table = HandleTable(Dummy, 2){};
    var a = Dummy{};
    const id_a = table.insert(&a).?;
    table.remove(id_a);
    try std.testing.expectEqual(@as(?*Dummy, null), table.get(id_a));
    var b = Dummy{};
    const id_b = table.insert(&b).?;
    try std.testing.expectEqual(id_a, id_b);
}

test "insert returns null once capacity is exhausted, never silently overwrites" {
    var table = HandleTable(Dummy, 1){};
    var a = Dummy{};
    var b = Dummy{};
    try std.testing.expect(table.insert(&a) != null);
    try std.testing.expectEqual(@as(?u32, null), table.insert(&b));
}

test "get with an out-of-range id returns null rather than an out-of-bounds access" {
    var table = HandleTable(Dummy, 2){};
    try std.testing.expectEqual(@as(?*Dummy, null), table.get(99));
}
