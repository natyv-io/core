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

/// W5: `.dismiss` is fired to a modal's own widget id on Escape or a
/// backdrop click -- discrete like `.click` (always appended, never
/// coalesced), since a guest deciding "should I actually close" needs
/// every request, not just the latest.
///
/// W6: `.text_changed` is the second continuous type (payload
/// `{"text":"..."}`) -- fired after every TextField edit, coalesced like
/// `.change` (a fast typer or a paste can append several times in one
/// frame; only the latest full text matters). `.blur` (fired to whatever
/// widget just lost focus) and `.key_nav` (fired to a focused TextField on
/// Up/Down/Enter, payload `{"key":"up"|"down"|"enter"}`) are both discrete
/// like `.click`/`.dismiss` -- never coalesced, every one matters.
///
/// W15: `.hover` (payload `{"hovering":bool}`) is fired to a widget when
/// main.zig's hover-hold timer crosses its threshold (true) and again the
/// moment that widget stops being hovered (false) -- see main.zig's own
/// doc comment on the timer for why the *state transition* is what's
/// reported, not a continuous stream. Coalesced like `.change`/
/// `.text_changed` rather than discrete like `.blur`/`.key_nav`: a hover
/// that starts and ends within the same undrained frame (a fast mouse
/// flick) should coalesce down to just the final `false`, since a guest
/// reacting to an intermediate `true` would only create a tooltip it'd
/// immediately have to tear back down. The guest still guards its
/// hover-off handling on "was a tooltip actually created" (same `!= 0`
/// idiom `closeDropdown`/`closeModal` already use for their own panel
/// ids) since coalescing narrows this edge case rather than eliminating
/// it entirely.
///
/// Tree view: `.scroll` (payload `{"scroll_offset_x":f,"scroll_offset_y":f}`) is fired to a scroll
/// container's own widget id whenever `ClayLayout.layoutIfNeeded`'s writeback loop sees its live
/// scroll offset actually change from what was last recorded -- see that function's own doc comment.
/// Coalesced like `.change`/`.text_changed`/`.hover`: a container can move every frame while actively
/// scrolling, and only the latest offset matters to a guest re-windowing a virtualized list.
pub const EventType = enum { click, change, dismiss, text_changed, blur, key_nav, hover, scroll };

pub const Entry = struct {
    widget_id: u32,
    event_type: EventType,
    /// Owned, heap-allocated -- free via `EventQueue.freeEntry` once done.
    payload: []u8,
    seq: u32,
    /// W5: which modal (if any) `widget_id` is nested under, or 0 (root/
    /// main surface) -- see FloatingOrder.surfaceIdFor. Carried on every
    /// event, not just modal-related ones, so a future surface kind
    /// (NativeWindow) needs no wire-contract change.
    surface_id: u32 = 0,
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

pub fn push(self: *Self, io: Io, widget_id: u32, event_type: EventType, payload: []const u8, surface_id: u32) void {
    const owned = self.allocator.dupe(u8, payload) catch |err| {
        std.debug.print("[queue]  DROPPED push, alloc failed: {}\n", .{err});
        return;
    };

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    // W3: coalesce with an already-queued (not yet popped -- `pop` removes
    // immediately via `orderedRemove`, so this can never merge with
    // something already delivered) entry of the *same* continuous type for
    // the same widget, overwriting its payload in place rather than
    // appending a second one. W6: `.text_changed` joins `.change` as a
    // second continuous type -- matched against `event_type` itself (not
    // hardcoded to `.change`) so the two families never cross-coalesce
    // with each other. W15: `.hover` joins the same coalesced family --
    // see its own EventType doc comment for why. Tree view: `.scroll`
    // joins it too, same reasoning.
    if (event_type == .change or event_type == .text_changed or event_type == .hover or event_type == .scroll) {
        for (self.items.items) |*existing| {
            if (existing.widget_id == widget_id and existing.event_type == event_type) {
                self.allocator.free(existing.payload);
                existing.payload = owned;
                self.seq_counter += 1;
                existing.seq = self.seq_counter;
                std.debug.print("[queue]  coalesced    widget={d} type={s} seq={d} (qlen={d})\n", .{ widget_id, @tagName(event_type), existing.seq, self.items.items.len });
                self.cond.signal(io);
                return;
            }
        }
    }

    self.seq_counter += 1;
    const seq = self.seq_counter;

    self.items.append(self.allocator, .{ .widget_id = widget_id, .event_type = event_type, .payload = owned, .seq = seq, .surface_id = surface_id }) catch |err| {
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

    queue.push(io, 1, .click, "a", 0);
    queue.push(io, 1, .click, "b", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "change events for the same widget coalesce to the latest payload" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .change, "{\"value\":0.1}", 0);
    queue.push(io, 1, .change, "{\"value\":0.9}", 0);
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

    queue.push(io, 1, .change, "a", 0);
    queue.push(io, 2, .change, "b", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "click and change for the same widget are independent, not coalesced with each other" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .click, "a", 0);
    queue.push(io, 1, .change, "b", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "a change event popped and then pushed again starts a fresh entry, not a stale merge" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .change, "a", 0);
    const popped = queue.pop(io).?;
    queue.freeEntry(popped);
    try std.testing.expectEqual(@as(usize, 0), queue.items.items.len);

    queue.push(io, 1, .change, "b", 0);
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqualStrings("b", queue.items.items[0].payload);
}

test "dismiss events for the same widget are never coalesced, matching click" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .dismiss, "", 0);
    queue.push(io, 1, .dismiss, "", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "text_changed events for the same widget coalesce to the latest payload" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .text_changed, "{\"text\":\"h\"}", 0);
    queue.push(io, 1, .text_changed, "{\"text\":\"hi\"}", 0);
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqualStrings("{\"text\":\"hi\"}", queue.items.items[0].payload);
}

test "change and text_changed for the same widget id don't cross-coalesce with each other" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .change, "a", 0);
    queue.push(io, 1, .text_changed, "b", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "hover events for the same widget coalesce to the latest payload" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .hover, "{\"hovering\":true}", 0);
    queue.push(io, 1, .hover, "{\"hovering\":false}", 0);
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqualStrings("{\"hovering\":false}", queue.items.items[0].payload);
}

test "hover events for different widgets don't coalesce with each other" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .hover, "{\"hovering\":true}", 0);
    queue.push(io, 2, .hover, "{\"hovering\":true}", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "hover and click for the same widget are independent, not coalesced with each other" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .click, "a", 0);
    queue.push(io, 1, .hover, "{\"hovering\":true}", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
}

test "blur and key_nav events are never coalesced, matching click/dismiss" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .blur, "", 0);
    queue.push(io, 1, .blur, "", 0);
    queue.push(io, 1, .key_nav, "{\"key\":\"down\"}", 0);
    queue.push(io, 1, .key_nav, "{\"key\":\"down\"}", 0);
    try std.testing.expectEqual(@as(usize, 4), queue.items.items.len);
}

test "push carries surface_id through to the popped entry" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .click, "a", 7);
    const popped = queue.pop(io).?;
    defer queue.freeEntry(popped);
    try std.testing.expectEqual(@as(u32, 7), popped.surface_id);
}
