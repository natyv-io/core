//! Generic {widget_id, event_type, payload} event queue -- no app-specific
//! Kind enum. Discrete events are always kept and delivered in order.
//!
//! W3: `change` is the first continuous event type -- a slider drag can
//! push far more per-frame updates than the worker thread could ever drain,
//! and only the latest value matters, so `push` coalesces a `.change` push
//! with any already-queued-but-not-yet-popped entry for the same widget_id
//! instead of appending a new one. `.click` (and any future genuinely
//! discrete type) is never coalesced -- always appended, unchanged from
//! before this existed. This is exactly what this file's own doc comment
//! predicted before either W3 or the slider it's for were built.

const std = @import("std");
const Io = std.Io;

const Self = @This();

pub const EventType = enum { click, change };

pub const Entry = struct {
    widget_id: u32,
    event_type: EventType,
    /// Owned, heap-allocated -- free via `EventQueue.freeEntry` once done.
    payload: []u8,
    seq: u32,
};

allocator: std.mem.Allocator,
mutex: Io.Mutex = .init,
cond: Io.Condition = .init,
items: std.ArrayList(Entry) = .empty,
seq_counter: u32 = 0,
shutdown: bool = false,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    for (self.items.items) |entry| self.allocator.free(entry.payload);
    self.items.deinit(self.allocator);
}

pub fn freeEntry(self: *Self, entry: Entry) void {
    self.allocator.free(entry.payload);
}

pub fn push(self: *Self, io: Io, widget_id: u32, event_type: EventType, payload: []const u8) void {
    const owned = self.allocator.dupe(u8, payload) catch |err| {
        std.debug.print("[queue]  DROPPED push, alloc failed: {}\n", .{err});
        return;
    };

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    // W3: coalesce with an already-queued (not yet popped -- `pop` removes
    // immediately via `orderedRemove`, so this can never merge with
    // something already delivered) `.change` entry for the same widget,
    // overwriting its payload in place rather than appending a second one.
    if (event_type == .change) {
        for (self.items.items) |*existing| {
            if (existing.widget_id == widget_id and existing.event_type == .change) {
                self.allocator.free(existing.payload);
                existing.payload = owned;
                self.seq_counter += 1;
                existing.seq = self.seq_counter;
                std.debug.print("[queue]  coalesced    widget={d} type=change seq={d} (qlen={d})\n", .{ widget_id, existing.seq, self.items.items.len });
                self.cond.signal(io);
                return;
            }
        }
    }

    self.seq_counter += 1;
    const seq = self.seq_counter;

    self.items.append(self.allocator, .{ .widget_id = widget_id, .event_type = event_type, .payload = owned, .seq = seq }) catch |err| {
        std.debug.print("[queue]  DROPPED push, alloc failed: {}\n", .{err});
        self.allocator.free(owned);
        return;
    };
    std.debug.print("[queue]  pushed       widget={d} type={s} seq={d} (qlen={d})\n", .{ widget_id, @tagName(event_type), seq, self.items.items.len });
    self.cond.signal(io);
}

pub fn pop(self: *Self, io: Io) ?Entry {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    while (self.items.items.len == 0) {
        if (self.shutdown) return null;
        self.cond.waitUncancelable(io, &self.mutex);
    }
    return self.items.orderedRemove(0);
}

pub fn requestShutdown(self: *Self, io: Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.shutdown = true;
    self.cond.broadcast(io);
}

fn testIo(threaded: *std.Io.Threaded) Io {
    return threaded.io();
}

test "click events for the same widget are never coalesced" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .click, "a");
    queue.push(io, 1, .click, "b");
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "change events for the same widget coalesce to the latest payload" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .change, "{\"value\":0.1}");
    queue.push(io, 1, .change, "{\"value\":0.9}");
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqualStrings("{\"value\":0.9}", queue.items.items[0].payload);
}

test "change events for different widgets don't coalesce with each other" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .change, "a");
    queue.push(io, 2, .change, "b");
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "click and change for the same widget are independent, not coalesced with each other" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .click, "a");
    queue.push(io, 1, .change, "b");
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "a change event popped and then pushed again starts a fresh entry, not a stale merge" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .change, "a");
    const popped = queue.pop(io).?;
    queue.freeEntry(popped);
    try std.testing.expectEqual(@as(usize, 0), queue.items.items.len);

    queue.push(io, 1, .change, "b");
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqualStrings("b", queue.items.items[0].payload);
}
