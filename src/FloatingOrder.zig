//! W4: for each widget, walks its parent_id chain and reports whether it is
//! itself floating (clay_style.floating) or nested under any ancestor that
//! is -- this is what main.zig's draw loop and click hit-testing use to
//! give floating subtrees (e.g. a dropdown's options panel) priority over
//! normal content, since Clay itself only computes *position* for a
//! floating element and has no opinion on natyv's own draw order or
//! hit-testing.
//!
//! W5: `modal` is a stricter version of `floating` (see ClayStyle's doc
//! comment) that additionally needs *ordering* between simultaneously-open
//! floating subtrees (which modal is topmost, for backdrop/input-blocking)
//! and a "which surface does this widget belong to" query for the dispatch
//! wire -- both added here, alongside the existing floating-or-not bucket,
//! since they're the same "walk the parent_id chain" shape.
//!
//! Pure, no SDL/Clay rendering calls -- unit-tested directly, same "pure
//! bucketing logic" precedent as ScrollClip.zig/DrawBatcher.add.

const WidgetHost = @import("widgets/WidgetHost.zig");

/// `slots` and `out` must be the same length; `out[i]` corresponds to
/// `slots[i]`. A modal is always floating-or-descendant too (see
/// isFloatingOrDescendant) -- this is deliberate: it lets the existing
/// `is_floating`-driven draw pass and floating-first hit-test pass already
/// cover modal subtrees with no separate machinery, and main.zig only needs
/// the modal-specific functions below for the genuinely new behaviors
/// (topmost-of-several, input-blocking, backdrop).
pub fn computeIsFloating(slots: []const WidgetHost.Slot, out: []bool) void {
    for (slots, 0..) |slot, i| out[i] = isFloatingOrDescendant(slots, slot);
}

fn isFloatingOrDescendant(slots: []const WidgetHost.Slot, slot: WidgetHost.Slot) bool {
    if (slot.clay_style.floating or slot.clay_style.modal) return true;
    var current = slot.parent_id;
    while (current) |id| {
        const parent = findSlot(slots, id) orelse break;
        if (parent.clay_style.floating or parent.clay_style.modal) return true;
        current = parent.parent_id;
    }
    return false;
}

/// The id of the topmost currently-open modal (highest id among widgets
/// with `clay_style.modal == true`), or null if none is open. Relies on
/// `WidgetHost.next_id` being monotonic and never reused (confirmed against
/// source) -- the most-recently-created modal root is always the highest
/// id, which is exactly "topmost" for a stack of simultaneously-open
/// modals, with no separate z-order counter needed.
pub fn topmostModalRoot(slots: []const WidgetHost.Slot) ?u32 {
    var topmost: ?u32 = null;
    for (slots) |slot| {
        if (!slot.clay_style.modal) continue;
        if (topmost == null or slot.id > topmost.?) topmost = slot.id;
    }
    return topmost;
}

/// True when `id` is `root_id` itself, or `root_id` appears anywhere in
/// `id`'s parent_id chain. Used to scope hit-testing/drawing to "everything
/// inside the topmost modal" regardless of how deeply nested it is.
pub fn isDescendantOfOrSelf(slots: []const WidgetHost.Slot, id: u32, root_id: u32) bool {
    if (id == root_id) return true;
    const slot = findSlot(slots, id) orelse return false;
    var current = slot.parent_id;
    while (current) |pid| {
        if (pid == root_id) return true;
        const parent = findSlot(slots, pid) orelse break;
        current = parent.parent_id;
    }
    return false;
}

/// The id of the nearest ancestor (or `id` itself) with `clay_style.modal
/// == true`, or 0 if none -- 0 is never a real widget id since
/// `WidgetHost.next_id` starts at 1, matching the zero-sentinel idiom
/// already used elsewhere (e.g. clay-fixture's "not currently open"
/// widget-id vars) rather than introducing a nullable field on the wire.
/// This is natyv's "surface_id": every dispatch event carries one, keyed
/// off which modal (if any) the event's own widget is nested under, so a
/// future NativeWindow surface can reuse the same wire field without a
/// contract change -- see EventQueue.zig/Dispatch.zig.
pub fn surfaceIdFor(slots: []const WidgetHost.Slot, id: u32) u32 {
    const slot = findSlot(slots, id) orelse return 0;
    if (slot.clay_style.modal) return slot.id;
    var current = slot.parent_id;
    while (current) |pid| {
        const parent = findSlot(slots, pid) orelse break;
        if (parent.clay_style.modal) return parent.id;
        current = parent.parent_id;
    }
    return 0;
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
        .widget = .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, false) },
        .parent_id = parent_id,
        .clay_style = .{ .floating = floating },
        .clay_managed = true,
    };
}

fn modalSlot(id: u32, parent_id: ?u32) WidgetHost.Slot {
    return .{
        .id = id,
        .widget = .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, true) },
        .parent_id = parent_id,
        .clay_style = .{ .modal = true },
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

test "a modal widget is floating too, with no separate flag needed" {
    var slots = [_]WidgetHost.Slot{
        modalSlot(1, null),
        containerSlot(2, 1, false), // content inside the modal
    };
    var out: [2]bool = undefined;
    computeIsFloating(&slots, &out);
    try std.testing.expectEqual(true, out[0]);
    try std.testing.expectEqual(true, out[1]);
}

test "topmostModalRoot is null when no modal is open" {
    var slots = [_]WidgetHost.Slot{ containerSlot(1, null, false), containerSlot(2, 1, true) };
    try std.testing.expectEqual(@as(?u32, null), topmostModalRoot(&slots));
}

test "topmostModalRoot picks the higher id among several open modals" {
    var slots = [_]WidgetHost.Slot{ modalSlot(3, null), modalSlot(9, null), modalSlot(5, null) };
    try std.testing.expectEqual(@as(?u32, 9), topmostModalRoot(&slots));
}

test "isDescendantOfOrSelf is true for the root itself and any depth of descendant" {
    var slots = [_]WidgetHost.Slot{
        modalSlot(1, null),
        containerSlot(2, 1, false),
        containerSlot(3, 2, false), // two levels deep
    };
    try std.testing.expect(isDescendantOfOrSelf(&slots, 1, 1));
    try std.testing.expect(isDescendantOfOrSelf(&slots, 2, 1));
    try std.testing.expect(isDescendantOfOrSelf(&slots, 3, 1));
}

test "isDescendantOfOrSelf is false for an unrelated widget" {
    var slots = [_]WidgetHost.Slot{ modalSlot(1, null), containerSlot(2, null, false) };
    try std.testing.expect(!isDescendantOfOrSelf(&slots, 2, 1));
}

test "surfaceIdFor returns 0 (root) for a widget with no modal ancestor" {
    var slots = [_]WidgetHost.Slot{ containerSlot(1, null, false), containerSlot(2, 1, true) };
    try std.testing.expectEqual(@as(u32, 0), surfaceIdFor(&slots, 2));
}

test "surfaceIdFor returns the modal's own id for the modal root and its descendants" {
    var slots = [_]WidgetHost.Slot{
        modalSlot(1, null),
        containerSlot(2, 1, false),
        containerSlot(3, 2, false),
    };
    try std.testing.expectEqual(@as(u32, 1), surfaceIdFor(&slots, 1));
    try std.testing.expectEqual(@as(u32, 1), surfaceIdFor(&slots, 3));
}

test "surfaceIdFor resolves nested modals to the nearest (innermost) one" {
    var slots = [_]WidgetHost.Slot{
        modalSlot(1, null),
        containerSlot(2, 1, false), // trigger for the nested modal, inside modal 1
        modalSlot(3, 2), // nested modal
        containerSlot(4, 3, false), // content inside the nested modal
    };
    try std.testing.expectEqual(@as(u32, 3), surfaceIdFor(&slots, 4));
    try std.testing.expectEqual(@as(u32, 1), surfaceIdFor(&slots, 2));
}
