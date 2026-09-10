//! Batches same-color rect fills across every widget in a frame into as few
//! `SDL_RenderFillRects` calls as possible, instead of one
//! `SDL_SetRenderDrawColor` + `SDL_RenderFillRect` pair per widget.
//! Confirmed directly against SDL3's real header that `SDL_RenderFillRects`
//! exists for exactly this: one call filling many rects that share the
//! current draw color.
//!
//! `add` is pure bucketing logic with no SDL dependency (only reads/writes
//! plain structs) and is unit-tested directly; only `flush` touches the
//! renderer, verified by code review + the existing visual click-through --
//! not a mocked-SDL instrumentation test, which isn't warranted at natyv's
//! widget-count scale (tens, not thousands, of on-screen widgets). A
//! rendering-loop concern, not a layout concern: applies to every widget
//! with a fill, Clay-managed or not -- `examples/counter`'s plain button
//! benefits too, not just Clay-backed apps.

const c = @import("c.zig").c;
const WidgetHost = @import("widgets/WidgetHost.zig");

const Self = @This();

/// Bumped 2026-09-07, 8 -> 32 -- sized against `clay-fixture`'s own then-
/// current baseline (button normal/flash, textfield normal/focused --
/// four), which badly undercounted a real, styled app: mail-natyv's own
/// `styles.ntss` alone declares 6 distinct `backgroundColor` tokens
/// (root/toolbarBtn/row/primaryBtn/secondaryBtn/dangerBtn), before even
/// counting host-side interaction-state colors (checkbox/toggle/radio,
/// hover/focus rings, etc.) layered on top -- a single frame showing a
/// full folder view (toolbar + N message rows, each with its own
/// checkbox) can genuinely need more than 8 distinct fill colors at once.
/// `add`'s own silent-drop-on-overflow behavior (see its doc comment)
/// meant exceeding the old cap didn't error or crash -- it just silently
/// stopped drawing some widgets' backgrounds for that frame, exactly the
/// real, live-reproduced "some message rows show no background fill"
/// symptom this was root-caused from. Same one-line-fix shape as
/// `WidgetHost.max_widgets`'s own bump just above in this arc -- heap
/// memory cost stays trivial (`rects` lives on `WindowManager.
/// WindowContext.draw_batcher`, a real per-window struct field, not a
/// stack-local, so there's no stack-overflow risk the way `max_widgets`
/// itself had to be fixed for elsewhere).
const max_colors = 32;

colors: [max_colors]c.SDL_Color = undefined,
rects: [max_colors][WidgetHost.max_widgets]c.SDL_FRect = undefined,
counts: [max_colors]usize = [_]usize{0} ** max_colors,
color_count: usize = 0,

fn colorEql(a: c.SDL_Color, b: c.SDL_Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

/// Adds one fill rect to whichever color bucket matches `color`, creating a
/// new bucket if none does yet. Silently drops the rect if either the
/// per-bucket or overall bucket capacity is exceeded -- both are sized
/// generously above natyv's real scale, so this is a safety bound rather
/// than an expected path, matching how the widget registry itself already
/// silently caps out at `max_widgets`.
pub fn add(self: *Self, color: c.SDL_Color, rect: c.SDL_FRect) void {
    for (0..self.color_count) |i| {
        if (colorEql(self.colors[i], color)) {
            if (self.counts[i] < WidgetHost.max_widgets) {
                self.rects[i][self.counts[i]] = rect;
                self.counts[i] += 1;
            }
            return;
        }
    }
    if (self.color_count < max_colors) {
        const i = self.color_count;
        self.colors[i] = color;
        self.rects[i][0] = rect;
        self.counts[i] = 1;
        self.color_count += 1;
    }
}

/// Issues one `SDL_RenderFillRects` call per distinct color bucketed since
/// the last flush, then resets for the next frame.
pub fn flush(self: *Self, renderer: ?*c.SDL_Renderer) void {
    for (0..self.color_count) |i| {
        _ = c.SDL_SetRenderDrawColor(renderer, self.colors[i].r, self.colors[i].g, self.colors[i].b, self.colors[i].a);
        _ = c.SDL_RenderFillRects(renderer, &self.rects[i][0], @intCast(self.counts[i]));
    }
    self.* = .{};
}

const std = @import("std");

test "same color merges into one bucket" {
    var batcher: Self = .{};
    const red: c.SDL_Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    batcher.add(red, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    batcher.add(red, .{ .x = 10, .y = 10, .w = 10, .h = 10 });

    try std.testing.expectEqual(@as(usize, 1), batcher.color_count);
    try std.testing.expectEqual(@as(usize, 2), batcher.counts[0]);
    try std.testing.expectEqual(@as(f32, 10), batcher.rects[0][1].x);
}

test "distinct colors get separate buckets" {
    var batcher: Self = .{};
    const red: c.SDL_Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const blue: c.SDL_Color = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    batcher.add(red, .{ .x = 0, .y = 0, .w = 10, .h = 10 });
    batcher.add(blue, .{ .x = 1, .y = 1, .w = 5, .h = 5 });
    batcher.add(red, .{ .x = 2, .y = 2, .w = 1, .h = 1 });

    try std.testing.expectEqual(@as(usize, 2), batcher.color_count);
    try std.testing.expectEqual(@as(usize, 2), batcher.counts[0]);
    try std.testing.expectEqual(@as(usize, 1), batcher.counts[1]);
}

test "flush resets bucket state for the next frame" {
    var batcher: Self = .{};
    batcher.add(.{ .r = 1, .g = 2, .b = 3, .a = 255 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 });
    try std.testing.expectEqual(@as(usize, 1), batcher.color_count);

    // No live SDL_Renderer in this test -- passing null is safe here only
    // because SDL_SetRenderDrawColor/SDL_RenderFillRects both accept a null
    // renderer and just report failure (checked against SDL3's real
    // header), which this test correctly ignores via `_ =`, same as every
    // other call site in this codebase.
    batcher.flush(null);
    try std.testing.expectEqual(@as(usize, 0), batcher.color_count);
}
