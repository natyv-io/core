//! Generic {widget_id, event_type, payload} event queue -- no app-specific
//! Kind enum. Discrete events are always kept and delivered in order; the
//! queue itself doesn't coalesce here since the only event type today
//! (click) is inherently discrete. A continuous event type added later
//! (e.g. a slider drag) would coalesce by (widget_id, event_type), same
//! policy the original prototype validated, just re-keyed generically.

const std = @import("std");
const Io = std.Io;

const Self = @This();

pub const EventType = enum { click };

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
