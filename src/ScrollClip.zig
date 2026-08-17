//! W2: for each widget, walks its parent_id chain and intersects the rect of
//! every Clay-managed ancestor with scroll_vertical/scroll_horizontal set,
//! producing the SDL clip rect main.zig's draw loop must apply before
//! drawing that widget -- or null if no ancestor scroll-clips it. Nested
//! scroll ancestors "just work" via intersection, not explicitly banned.
//!
//! Pure, no SDL rendering calls -- unit-tested directly, same "pure
//! bucketing logic" precedent as DrawBatcher.add.

const c = @import("c.zig").c;
const WidgetHost = @import("widgets/WidgetHost.zig");

/// `slots` and `out` must be the same length; `out[i]` corresponds to
/// `slots[i]`. Takes `[]WidgetHost.Slot` (not const) because reading a
/// widget's own rect goes through `Widget.rectPtr()`, which requires
/// `*Widget`.
pub fn computeClipRects(slots: []WidgetHost.Slot, out: []?c.SDL_FRect) void {
    for (slots, 0..) |*slot, i| out[i] = clipRectFor(slots, slot.parent_id);
}

fn clipRectFor(slots: []WidgetHost.Slot, parent_id: ?u32) ?c.SDL_FRect {
    var result: ?c.SDL_FRect = null;
    var current = parent_id;
    while (current) |id| {
        const parent = findSlot(slots, id) orelse break;
        if (parent.clay_style.scroll_vertical or parent.clay_style.scroll_horizontal) {
            result = intersect(result, parent.widget.rectPtr().*);
        }
        current = parent.parent_id;
    }
    return result;
}

fn findSlot(slots: []WidgetHost.Slot, id: u32) ?*WidgetHost.Slot {
    for (slots) |*s| if (s.id == id) return s;
    return null;
}

fn intersect(a: ?c.SDL_FRect, b: c.SDL_FRect) c.SDL_FRect {
    const base = a orelse return b;
    const x0 = @max(base.x, b.x);
    const y0 = @max(base.y, b.y);
    const x1 = @min(base.x + base.w, b.x + b.w);
    const y1 = @min(base.y + base.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

const std = @import("std");
const Container = @import("widgets/Container.zig");

fn containerSlot(id: u32, parent_id: ?u32, rect: c.SDL_FRect, scroll_vertical: bool, scroll_horizontal: bool) WidgetHost.Slot {
    return .{
        .id = id,
        .widget = .{ .container = Container.init(rect, false) },
        .parent_id = parent_id,
        .clay_style = .{ .scroll_vertical = scroll_vertical, .scroll_horizontal = scroll_horizontal },
        .clay_managed = true,
    };
}

fn leafSlot(id: u32, parent_id: ?u32) WidgetHost.Slot {
    return .{
        .id = id,
        .widget = .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) },
        .parent_id = parent_id,
        .clay_style = .{},
        .clay_managed = true,
    };
}

test "no scroll ancestor anywhere in the chain returns null" {
    var slots = [_]WidgetHost.Slot{
        containerSlot(1, null, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, false, false),
        leafSlot(2, 1),
    };
    var out: [2]?c.SDL_FRect = undefined;
    computeClipRects(&slots, &out);
    try std.testing.expectEqual(@as(?c.SDL_FRect, null), out[0]);
    try std.testing.expectEqual(@as(?c.SDL_FRect, null), out[1]);
}

test "one direct scroll-container parent clips exactly to its rect" {
    var slots = [_]WidgetHost.Slot{
        containerSlot(1, null, .{ .x = 10, .y = 20, .w = 200, .h = 300 }, true, false),
        leafSlot(2, 1),
    };
    var out: [2]?c.SDL_FRect = undefined;
    computeClipRects(&slots, &out);
    try std.testing.expectEqual(@as(?c.SDL_FRect, null), out[0]); // the scroll container itself clips its children, not itself
    try std.testing.expect(out[1] != null);
    try std.testing.expectEqual(@as(f32, 10), out[1].?.x);
    try std.testing.expectEqual(@as(f32, 20), out[1].?.y);
    try std.testing.expectEqual(@as(f32, 200), out[1].?.w);
    try std.testing.expectEqual(@as(f32, 300), out[1].?.h);
}

test "two nested scroll ancestors intersect, not just use the nearer one" {
    var slots = [_]WidgetHost.Slot{
        containerSlot(1, null, .{ .x = 0, .y = 0, .w = 200, .h = 200 }, true, true),
        containerSlot(2, 1, .{ .x = 50, .y = 50, .w = 100, .h = 300 }, true, false),
        leafSlot(3, 2),
    };
    var out: [3]?c.SDL_FRect = undefined;
    computeClipRects(&slots, &out);
    try std.testing.expect(out[2] != null);
    // Intersection of {0,0,200,200} and {50,50,100,300} is {50,50,100,150}.
    try std.testing.expectEqual(@as(f32, 50), out[2].?.x);
    try std.testing.expectEqual(@as(f32, 50), out[2].?.y);
    try std.testing.expectEqual(@as(f32, 100), out[2].?.w);
    try std.testing.expectEqual(@as(f32, 150), out[2].?.h);
}

test "a plain non-scroll container between a widget and a further scroll ancestor is walked through" {
    var slots = [_]WidgetHost.Slot{
        containerSlot(1, null, .{ .x = 5, .y = 5, .w = 400, .h = 400 }, true, false),
        containerSlot(2, 1, .{ .x = 10, .y = 10, .w = 300, .h = 300 }, false, false), // plain grouping node
        leafSlot(3, 2),
    };
    var out: [3]?c.SDL_FRect = undefined;
    computeClipRects(&slots, &out);
    try std.testing.expect(out[2] != null);
    try std.testing.expectEqual(@as(f32, 5), out[2].?.x);
    try std.testing.expectEqual(@as(f32, 5), out[2].?.y);
    try std.testing.expectEqual(@as(f32, 400), out[2].?.w);
    try std.testing.expectEqual(@as(f32, 400), out[2].?.h);
}
