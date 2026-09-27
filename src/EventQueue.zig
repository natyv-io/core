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
const builtin = @import("builtin");
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
///
/// W23: `.file_selected` (payload `{"paths":["...",...]}`, empty array for a cancelled dialog or a
/// real SDL-level error -- see `WidgetHost.pending_file_dialog_request`'s own doc comment for why the
/// wire contract doesn't distinguish the two) is fired to the trigger widget id that originally called
/// `natyv_show_open_file_dialog`/`natyv_show_save_file_dialog`, once SDL's own callback actually
/// fires. Discrete, not coalesced -- a guest awaiting a real dialog result needs the actual result,
/// not whatever happened to still be queued, same reasoning `.click`/`.dismiss`/`.blur`/`.key_nav`
/// already established.
///
/// Multi-window Stage 4: `.window_close_requested` (empty payload) is fired to a window's own
/// `window_root` widget id when the OS reports `SDL_EVENT_WINDOW_CLOSE_REQUESTED` for that window (see
/// `main.zig`'s own doc comment on this handling) -- never fired for the original startup window,
/// which quits the whole app unconditionally instead. The host does not destroy anything on its own;
/// if the guest never handles this (or handles it and does nothing), the window just stays open. Same
/// deliberate idiom as Escape-on-a-modal-with-no-handler already being a no-op (see `ClayStyle.modal`'s
/// own doc comment), and what makes an "unsaved changes?" veto flow possible at near-zero extra cost.
/// Discrete, not coalesced -- same reasoning `.dismiss` already established: a guest deciding whether
/// to actually close needs every request, not just whichever happened to still be queued.
///
/// HID: `.hid_report` (payload `{"data":"<base64>"}`, plus `"dropped":N` when reports were lost since
/// the last one delivered) and `.hid_disconnected` (payload `{}`) are addressed to an open HID handle's
/// id, not a widget -- see `HidRegistry.zig`. Discrete, never coalesced: a report is a keypress, and a
/// dropped keypress is a bug. Pushed through `pushBounded` instead, so a device that streams faster than
/// the guest drains can't grow this queue without limit. Both also survive a recycle (see `pop`).
pub const EventType = enum { click, change, dismiss, text_changed, blur, key_nav, hover, scroll, file_selected, window_close_requested, hid_report, hid_disconnected };

/// Whether an entry of this type is still meaningful after a recycle -- see `pop`. A widget id is
/// rebuilt fresh by `natyv_resume`, so an event addressed to one is stale. A HID handle is not: the
/// device stays open across a recycle and the resumed guest reclaims the same id (see
/// `HidRegistry.claimByPath`), so a report that arrived mid-resume still has a real recipient.
fn survivesRecycle(event_type: EventType) bool {
    return event_type == .hid_report or event_type == .hid_disconnected;
}

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
    /// Stamped from the queue's own `generation` at push time -- see
    /// `bumpGeneration`'s own doc comment for why this exists and what
    /// `pop` does with it.
    generation: u32 = 0,
};

allocator: std.mem.Allocator,
mutex: Io.Mutex = .init,
cond: Io.Condition = .init,
items: std.ArrayList(Entry) = .empty,
seq_counter: u32 = 0,
shutdown: bool = false,
/// Bumped by `bumpGeneration` after every real recycle -- see its own doc
/// comment. Every entry still sitting in the queue (or arriving from the
/// main thread microseconds later, mid-recycle) at that point was stamped
/// with an older value at push time, and `pop` silently discards rather
/// than returns it.
generation: u32 = 0,

/// Per-event queue tracing. Silent under `zig build test`: these fire on
/// every single push, so in a unit test they are pure noise -- and Zig's
/// build runner echoes any step that produced *any* stderr as
/// `failed command: ...` even when that step passed (build_runner.zig's
/// "No matter the result, we want to display error/warning messages"
/// block, gated on `result_stderr.len > 0`). That message is
/// indistinguishable from a real build failure and cost a real debugging
/// session. Genuine failures below (a dropped push on alloc failure) stay
/// unconditional -- those are errors, not traces.
fn trace(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt, args);
}

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
                trace("[queue]  coalesced    widget={d} type={s} seq={d} (qlen={d})\n", .{ widget_id, @tagName(event_type), existing.seq, self.items.items.len });
                self.cond.signal(io);
                return;
            }
        }
    }

    self.seq_counter += 1;
    const seq = self.seq_counter;

    self.items.append(self.allocator, .{ .widget_id = widget_id, .event_type = event_type, .payload = owned, .seq = seq, .surface_id = surface_id, .generation = self.generation }) catch |err| {
        std.debug.print("[queue]  DROPPED push, alloc failed: {}\n", .{err});
        self.allocator.free(owned);
        return;
    };
    trace("[queue]  pushed       widget={d} type={s} seq={d} (qlen={d})\n", .{ widget_id, @tagName(event_type), seq, self.items.items.len });
    self.cond.signal(io);
}

/// `push` for a discrete event from a source that can outrun the guest -- appends only while fewer
/// than `max_queued` entries of `event_type` for `widget_id` are waiting, and returns whether it did.
/// A refusal is the caller's to count and report (see `HidRegistry`'s reader), never silent: the
/// alternative of blocking the producer just moves the loss somewhere it can't be counted.
pub fn pushBounded(self: *Self, io: Io, widget_id: u32, event_type: EventType, payload: []const u8, surface_id: u32, max_queued: usize) bool {
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var queued: usize = 0;
        for (self.items.items) |existing| {
            if (existing.widget_id == widget_id and existing.event_type == event_type) queued += 1;
        }
        if (queued >= max_queued) return false;
    }
    // Only this producer pushes events for `widget_id`, so the count can't grow between the check
    // above and `push` below -- `pop` can only shrink it.
    self.push(io, widget_id, event_type, payload, surface_id);
    return true;
}

/// Drops every queued entry addressed to `widget_id`. For a HID handle being closed: its reader
/// thread has already been joined, so nothing can arrive after this, and a guest that called
/// `hid_close` shouldn't then receive reports for the handle it just closed.
pub fn removeAllFor(self: *Self, io: Io, widget_id: u32) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    var i: usize = 0;
    while (i < self.items.items.len) {
        if (self.items.items[i].widget_id == widget_id) {
            self.allocator.free(self.items.orderedRemove(i).payload);
        } else {
            i += 1;
        }
    }
}

pub fn pop(self: *Self, io: Io) ?Entry {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    while (true) {
        while (self.items.items.len == 0) {
            if (self.shutdown) return null;
            self.cond.waitUncancelable(io, &self.mutex);
        }
        const entry = self.items.orderedRemove(0);
        if (entry.generation != self.generation and !survivesRecycle(entry.event_type)) {
            // Stale -- queued before the most recent recycle. See
            // bumpGeneration's own doc comment for why silently discarding
            // this (instead of returning it for dispatch against an id
            // that no longer exists on the freshly-rebuilt instance) is
            // correct, not a data loss.
            self.allocator.free(entry.payload);
            continue;
        }
        return entry;
    }
}

/// Marks every entry currently queued (or arriving from the main thread
/// microseconds from now, mid-recycle) as stale -- called by `Dispatch.zig`
/// right after a real recycle swap completes. A recycle rebuilds the
/// entire widget tree with fresh ids; an event queued *before* it, whether
/// already sitting in the queue or pushed while `natyv_resume` was still
/// running (a real, ~1-second-plus window -- more than enough time for a
/// genuine, real user click to land in it), carries an old id that means
/// nothing dispatched against the new instance. Confirmed live: such a
/// click previously looked indistinguishable from "nothing happened" --
/// the dispatch itself succeeded, silently no-opping against a guest-side
/// handler map that has nothing registered for that now-meaningless id.
/// `pop` is what actually discards a stale entry, using the generation
/// this stamps going forward; nothing already popped is affected.
pub fn bumpGeneration(self: *Self, io: Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.generation +%= 1;
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

test "file_selected events are never coalesced, matching click/dismiss/blur/key_nav" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .file_selected, "{\"paths\":[]}", 0);
    queue.push(io, 1, .file_selected, "{\"paths\":[\"/tmp/a.txt\"]}", 0);
    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
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

test "pushBounded appends up to the cap per id and type, then refuses" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    try std.testing.expect(queue.pushBounded(io, 1, .hid_report, "a", 0, 2));
    try std.testing.expect(queue.pushBounded(io, 1, .hid_report, "b", 0, 2));
    try std.testing.expect(!queue.pushBounded(io, 1, .hid_report, "c", 0, 2));
    // Another id, and another type for the same id, each have their own count.
    try std.testing.expect(queue.pushBounded(io, 2, .hid_report, "d", 0, 2));
    try std.testing.expect(queue.pushBounded(io, 1, .hid_disconnected, "{}", 0, 2));
    try std.testing.expectEqual(@as(usize, 4), queue.items.items.len);

    // Draining one makes room again, and nothing was coalesced along the way.
    const popped = queue.pop(io).?;
    defer queue.freeEntry(popped);
    try std.testing.expectEqualStrings("a", popped.payload);
    try std.testing.expect(queue.pushBounded(io, 1, .hid_report, "e", 0, 2));
}

test "removeAllFor drops only the named id's entries, keeping the rest in order" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .hid_report, "a", 0);
    queue.push(io, 2, .click, "b", 0);
    queue.push(io, 1, .hid_report, "c", 0);
    queue.push(io, 1, .hid_disconnected, "{}", 0);
    queue.push(io, 3, .click, "d", 0);
    queue.removeAllFor(io, 1);

    try std.testing.expectEqual(@as(usize, 2), queue.items.items.len);
    try std.testing.expectEqualStrings("b", queue.items.items[0].payload);
    try std.testing.expectEqualStrings("d", queue.items.items[1].payload);
}

test "HID events survive a recycle's generation bump; widget events don't" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = testIo(&threaded);

    var queue = Self.init(allocator);
    defer queue.deinit();

    queue.push(io, 1, .click, "stale", 0);
    queue.push(io, 2, .hid_report, "report", 0);
    queue.push(io, 2, .hid_disconnected, "{}", 0);
    queue.bumpGeneration(io);
    // Keeps `pop` from blocking forever if a regression discards the HID
    // entries too -- it then returns this instead and the check below fails.
    queue.push(io, 3, .click, "fresh", 0);

    const first = queue.pop(io).?;
    defer queue.freeEntry(first);
    try std.testing.expectEqual(EventType.hid_report, first.event_type);
    const second = queue.pop(io).?;
    defer queue.freeEntry(second);
    try std.testing.expectEqual(EventType.hid_disconnected, second.event_type);
    const third = queue.pop(io).?;
    defer queue.freeEntry(third);
    try std.testing.expectEqualStrings("fresh", third.payload);
    try std.testing.expectEqual(@as(usize, 0), queue.items.items.len);
}
