//! W17: a fixed row of mutually-exclusive labeled segments, one focus stop
//! (unlike Menu/Dropdown, which compose a separate Button/Label widget per
//! item -- that would reintroduce the multi-Tab-stop problem this widget
//! exists to avoid; see `NumericStepper.zig`'s file doc comment for the
//! same reasoning applied to the Date & time picker's steppers). Bounded
//! label storage follows `TextField.zig`'s exact fixed-buffer convention.

const std = @import("std");
const text_cursor = @import("text_cursor.zig");
const c = @import("../c.zig").c;

const Self = @This();

pub const max_segments = 6;
pub const max_label_len = 24;

rect: c.SDL_FRect,
labels: [max_segments][max_label_len + 1]u8 = undefined,
label_lens: [max_segments]usize = [_]usize{0} ** max_segments,
count: usize,
selected_index: usize = 0,
/// Keyboard interaction model: see Button.focused's doc comment.
focused: bool = false,

// F3-style cached TTF_Text handles, one per segment -- see Badge.zig's
// fields of the same name/purpose for the general shape. Unlike Badge/
// Button, a segment's label never changes after creation (there's no
// `natyv_set_text` equivalent for an individual segment in v1), so there's
// no generation counter to diff against: each is created once, lazily, in
// `syncText`, and never updated afterward.
text_objs: [max_segments]?*c.TTF_Text = [_]?*c.TTF_Text{null} ** max_segments,
sync_count: u32 = 0,

pub fn init(rect: c.SDL_FRect, labels: []const []const u8, selected_index: usize) Self {
    var self: Self = .{ .rect = rect, .count = @min(labels.len, max_segments) };
    for (0..self.count) |i| {
        const n = text_cursor.truncatedLen(labels[i], max_label_len);
        @memcpy(self.labels[i][0..n], labels[i][0..n]);
        self.labels[i][n] = 0;
        self.label_lens[i] = n;
    }
    self.select(selected_index);
    return self;
}

fn labelText(self: *const Self, i: usize) []const u8 {
    return self.labels[i][0..self.label_lens[i]];
}

/// Clamps to `[0, count - 1]`, or stays 0 if `count` is 0 (an empty
/// control -- degenerate input, not expected in practice, but shouldn't
/// panic or read out of bounds).
pub fn select(self: *Self, index: usize) void {
    if (self.count == 0) {
        self.selected_index = 0;
        return;
    }
    self.selected_index = @min(index, self.count - 1);
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

/// Divides `rect.w` into `count` equal columns and returns the index under
/// `(x, y)`, or `null` outside the rect (or if `count` is 0). The new
/// "multiple independently-clickable zones inside one rect" pattern
/// `NumericStepper.regionAt` also establishes, generalized from two fixed
/// zones to N equal ones.
pub fn segmentAt(self: Self, x: f32, y: f32) ?usize {
    if (self.count == 0 or !self.containsPoint(x, y)) return null;
    const seg_w = self.rect.w / @as(f32, @floatFromInt(self.count));
    if (seg_w <= 0) return null;
    const idx = std.math.lossyCast(usize, @floor((x - self.rect.x) / seg_w));
    return @min(idx, self.count - 1);
}

/// `count` equal segments, the `selected_index` one filled in the "active"
/// color (same blue `Slider`'s track-fill already uses), the rest in the
/// neutral widget color. Opts out of the single-color batched fill the
/// same way `Slider`/`NumericStepper` do, since this is a multi-region
/// custom draw.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    if (self.count == 0) return;
    const seg_w = self.rect.w / @as(f32, @floatFromInt(self.count));
    for (0..self.count) |i| {
        const seg_rect: c.SDL_FRect = .{ .x = self.rect.x + seg_w * @as(f32, @floatFromInt(i)), .y = self.rect.y, .w = seg_w, .h = self.rect.h };
        if (i == self.selected_index) {
            _ = c.SDL_SetRenderDrawColor(renderer, 70, 140, 230, 255);
        } else {
            _ = c.SDL_SetRenderDrawColor(renderer, 60, 65, 80, 255);
        }
        _ = c.SDL_RenderFillRect(renderer, &seg_rect);
        _ = c.SDL_SetRenderDrawColor(renderer, 140, 140, 150, 255);
        _ = c.SDL_RenderRect(renderer, &seg_rect);

        if (self.text_objs[i]) |obj| {
            var w: c_int = 0;
            var h: c_int = 0;
            _ = c.TTF_GetTextSize(obj, &w, &h);
            _ = c.TTF_DrawRendererText(obj, seg_rect.x + seg_rect.w / 2 - @as(f32, @floatFromInt(w)) / 2, seg_rect.y + seg_rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
        }
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

/// See the file doc comment on `text_objs` -- unlike `Button.syncText`/
/// `Badge.syncText`, there's no generation counter to check: each segment's
/// `TTF_Text` is created once, lazily, and never touched again afterward.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
    for (0..self.count) |i| {
        if (self.text_objs[i] == null) {
            if (c.TTF_CreateText(engine, font, self.labelText(i).ptr, self.label_lens[i])) |obj| {
                _ = c.TTF_SetTextColor(obj, 255, 255, 255, 255);
                self.text_objs[i] = obj;
                self.sync_count += 1;
            }
        }
    }
}

/// See `Button.destroyText`'s doc comment -- destroys every segment's text
/// object, not just one.
pub fn destroyText(self: *Self) void {
    for (0..self.count) |i| {
        if (self.text_objs[i]) |obj| {
            c.TTF_DestroyText(obj);
            self.text_objs[i] = null;
        }
    }
}

fn testControl(count: usize, selected: usize) Self {
    var labels_buf: [max_segments][]const u8 = undefined;
    const names = [_][]const u8{ "One", "Two", "Three", "Four", "Five", "Six" };
    for (0..count) |i| labels_buf[i] = names[i];
    return init(.{ .x = 10, .y = 20, .w = 120, .h = 24 }, labels_buf[0..count], selected);
}

test "segmentAt divides the rect into count equal columns (3 segments)" {
    const s = testControl(3, 0);
    // rect x=10..130, 3 segments of width 40: [10,50) [50,90) [90,130)
    try std.testing.expectEqual(@as(?usize, 0), s.segmentAt(15, 30));
    try std.testing.expectEqual(@as(?usize, 1), s.segmentAt(60, 30));
    try std.testing.expectEqual(@as(?usize, 2), s.segmentAt(125, 30));
}

test "segmentAt divides the rect into count equal columns (4 segments)" {
    const s = testControl(4, 0);
    // rect x=10..130, 4 segments of width 30: [10,40) [40,70) [70,100) [100,130)
    try std.testing.expectEqual(@as(?usize, 0), s.segmentAt(20, 30));
    try std.testing.expectEqual(@as(?usize, 3), s.segmentAt(129, 30));
}

test "segmentAt returns null outside the rect" {
    const s = testControl(3, 0);
    try std.testing.expectEqual(@as(?usize, null), s.segmentAt(5, 30));
    try std.testing.expectEqual(@as(?usize, null), s.segmentAt(200, 30));
}

test "select clamps an out-of-range index to the last segment" {
    var s = testControl(3, 0);
    s.select(99);
    try std.testing.expectEqual(@as(usize, 2), s.selected_index);
}

test "init truncates labels over max_label_len and copies count correctly" {
    const long = "a" ** (max_label_len + 10);
    var s = init(.{ .x = 0, .y = 0, .w = 60, .h = 20 }, &.{ long, "ok" }, 1);
    try std.testing.expectEqual(@as(usize, 2), s.count);
    try std.testing.expectEqual(@as(usize, max_label_len), s.label_lens[0]);
    try std.testing.expectEqualStrings("ok", s.labelText(1));
    try std.testing.expectEqual(@as(usize, 1), s.selected_index);
}
