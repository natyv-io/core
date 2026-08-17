//! W4: for each widget, walks its parent_id chain and reports whether it is
//! itself floating (clay_style.floating) or nested under any ancestor that
//! is -- this is what main.zig's draw loop and click hit-testing use to
//! give floating subtrees (e.g. a dropdown's options panel) priority over
//! normal content, since Clay itself only computes *position* for a
//! floating element and has no opinion on natyv's own draw order or
//! hit-testing.
//!
//! Pure, no SDL/Clay rendering calls -- unit-tested directly, same "pure
//! bucketing logic" precedent as ScrollClip.zig/DrawBatcher.add.

const WidgetHost = @import("widgets/WidgetHost.zig");

/// `slots` and `out` must be the same length; `out[i]` corresponds to
/// `slots[i]`.
pub fn computeIsFloating(slots: []const WidgetHost.Slot, out: []bool) void {
    for (slots, 0..) |slot, i| out[i] = isFloatingOrDescendant(slots, slot);
}

fn isFloatingOrDescendant(slots: []const WidgetHost.Slot, slot: WidgetHost.Slot) bool {
    if (slot.clay_style.floating) return true;
    var current = slot.parent_id;
    while (current) |id| {
        const parent = findSlot(slots, id) orelse break;
        if (parent.clay_style.floating) return true;
        current = parent.parent_id;
    }
    return false;
}

fn findSlot(slots: []const WidgetHost.Slot, id: u32) ?WidgetHost.Slot {
    for (slots) |s| if (s.id == id) return s;
    return null;
}

const std = @import("std");
const Container = @import("widgets/Container.zig");

fn containerSlot(id: u32, parent_id: ?u32, floating: bool) WidgetHost.Slot {
    return .{
        .id = id,
        .widget = .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }) },
        .parent_id = parent_id,
        .clay_style = .{ .floating = floating },
        .clay_managed = true,
    };
}

test "a widget with no floating ancestor anywhere in the chain is not floating" {
    var slots = [_]WidgetHost.Slot{
        containerSlot(1, null, false),
        containerSlot(2, 1, false),
    };
    var out: [2]bool = undefined;
    computeIsFloating(&slots, &out);
    try std.testing.expectEqual(false, out[0]);
    try std.testing.expectEqual(false, out[1]);
}

test "a widget declared floating itself is floating" {
    var slots = [_]WidgetHost.Slot{
        containerSlot(1, null, false),
        containerSlot(2, 1, true),
    };
    var out: [2]bool = undefined;
    computeIsFloating(&slots, &out);
    try std.testing.expectEqual(false, out[0]);
    try std.testing.expectEqual(true, out[1]);
}

test "a descendant two levels under a floating ancestor is floating" {
    var slots = [_]WidgetHost.Slot{
        containerSlot(1, null, false), // trigger
        containerSlot(2, 1, true), // floating options panel
        containerSlot(3, 2, false), // an option row inside the panel
    };
    var out: [3]bool = undefined;
    computeIsFloating(&slots, &out);
    try std.testing.expectEqual(false, out[0]);
    try std.testing.expectEqual(true, out[1]);
    try std.testing.expectEqual(true, out[2]);
}

test "a sibling not under the floating ancestor stays non-floating" {
    var slots = [_]WidgetHost.Slot{
        containerSlot(1, null, false), // trigger
        containerSlot(2, 1, true), // floating options panel
        containerSlot(3, null, false), // unrelated top-level widget elsewhere on screen
    };
    var out: [3]bool = undefined;
    computeIsFloating(&slots, &out);
    try std.testing.expectEqual(false, out[0]);
    try std.testing.expectEqual(true, out[1]);
    try std.testing.expectEqual(false, out[2]);
}
