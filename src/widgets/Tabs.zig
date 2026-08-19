//! W19: a fixed row of mutually-exclusive labeled tab headers, drawn by this
//! widget itself, paired with real Clay-managed panel children laid out
//! below the header strip. Unlike `SegmentedControl.zig` (a leaf widget with
//! no children of its own), Tabs both draws its own header decoration AND
//! is the real Clay parent of its panels -- the same "host-drawn decoration
//! + real Clay children in the same box" shape `Container.zig` already has,
//! combined with `SegmentedControl`'s internal-zone hit-testing on top.
//!
//! Panel visibility is owned by the host (see `WidgetHost.setActiveTab` and
//! the `ClayStyle.visible` flag it flips) -- this struct only tracks which
//! panel ids belong to it and which index is currently selected; it never
//! decides visibility itself.

const std = @import("std");
const c = @import("../c.zig").c;

const Self = @This();

pub const max_tabs = 6;
pub const max_label_len = 24;
/// Fixed header strip height, same precedent as `NumericStepper`'s fixed
/// 24px zone width -- easy to promote to a per-instance request field later
/// if needed, not worth the scope now.
pub const header_height: f32 = 36;

/// Whole widget box: header strip on top, Clay-laid-out panel area below.
rect: c.SDL_FRect,
labels: [max_tabs][max_label_len + 1]u8 = undefined,
label_lens: [max_tabs]usize = [_]usize{0} ** max_tabs,
count: usize,
selected_index: usize = 0,
/// Ids of this Tabs widget's panel `Container` children, in tab order --
/// populated by `WidgetHost`'s `natyv_clay_create_tab_panel` handling as
/// each panel is created, not by this struct itself.
panel_ids: [max_tabs]u32 = [_]u32{0} ** max_tabs,
panel_count: usize = 0,
/// Keyboard interaction model: see Button.focused's doc comment.
focused: bool = false,

// F3-style cached TTF_Text handles, one per tab label -- see
// `SegmentedControl.text_objs`'s doc comment for the general shape and
// same "created once, never updated" reasoning.
text_objs: [max_tabs]?*c.TTF_Text = [_]?*c.TTF_Text{null} ** max_tabs,
sync_count: u32 = 0,

pub fn init(rect: c.SDL_FRect, labels: []const []const u8, selected_index: usize) Self {
    var self: Self = .{ .rect = rect, .count = @min(labels.len, max_tabs) };
    for (0..self.count) |i| {
        const n = @min(labels[i].len, max_label_len);
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

/// The clickable/drawable header strip: `rect` with height clamped to
/// `header_height` -- a click or draw below this is real panel content,
/// not part of this widget's own decoration.
pub fn headerRect(self: Self) c.SDL_FRect {
    return .{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.w, .h = @min(self.rect.h, header_height) };
}

/// Clamps to `[0, count - 1]`, or stays 0 if `count` is 0 (an empty
/// control -- degenerate input, not expected in practice, but shouldn't
/// panic or read out of bounds). Same shape as `SegmentedControl.select`.
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

/// Divides the header strip's width into `count` equal columns and returns
/// the index under `(x, y)`, or `null` outside the header strip entirely
/// (including a click below `header_height`, which belongs to real panel
/// content instead). Same "N equal zones" pattern as
/// `SegmentedControl.segmentAt`, restricted to `headerRect()`.
pub fn tabAt(self: Self, x: f32, y: f32) ?usize {
    if (self.count == 0) return null;
    const hr = self.headerRect();
    if (x < hr.x or x >= hr.x + hr.w or y < hr.y or y >= hr.y + hr.h) return null;
    const tab_w = hr.w / @as(f32, @floatFromInt(self.count));
    if (tab_w <= 0) return null;
    const idx: usize = @intFromFloat(@floor((x - hr.x) / tab_w));
    return @min(idx, self.count - 1);
}

/// Draws only the header strip -- `count` equal tab cells, the
/// `selected_index` one filled in the "active" color (same blue
/// `SegmentedControl`'s selected segment uses), the rest neutral. The panel
/// area below is real Clay content, drawn by the normal per-child draw
/// pass, not by this function. Opts out of the single-color batched fill
/// the same way `SegmentedControl`/`Slider`/`NumericStepper` do.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    if (self.count == 0) return;
    const hr = self.headerRect();
    const tab_w = hr.w / @as(f32, @floatFromInt(self.count));
    for (0..self.count) |i| {
        const tab_rect: c.SDL_FRect = .{ .x = hr.x + tab_w * @as(f32, @floatFromInt(i)), .y = hr.y, .w = tab_w, .h = hr.h };
        if (i == self.selected_index) {
            _ = c.SDL_SetRenderDrawColor(renderer, 70, 140, 230, 255);
        } else {
            _ = c.SDL_SetRenderDrawColor(renderer, 60, 65, 80, 255);
        }
        _ = c.SDL_RenderFillRect(renderer, &tab_rect);
        _ = c.SDL_SetRenderDrawColor(renderer, 140, 140, 150, 255);
        _ = c.SDL_RenderRect(renderer, &tab_rect);

        if (self.text_objs[i]) |obj| {
            var w: c_int = 0;
            var h: c_int = 0;
            _ = c.TTF_GetTextSize(obj, &w, &h);
            _ = c.TTF_DrawRendererText(obj, tab_rect.x + tab_rect.w / 2 - @as(f32, @floatFromInt(w)) / 2, tab_rect.y + tab_rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
        }
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = hr.x - 1, .y = hr.y - 1, .w = hr.w + 2, .h = hr.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

/// See `SegmentedControl.syncText`'s doc comment -- each tab's `TTF_Text` is
/// created once, lazily, and never touched again afterward.
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

/// See `SegmentedControl.destroyText`'s doc comment.
pub fn destroyText(self: *Self) void {
    for (0..self.count) |i| {
        if (self.text_objs[i]) |obj| {
            c.TTF_DestroyText(obj);
            self.text_objs[i] = null;
        }
    }
}

fn testControl(count: usize, selected: usize) Self {
    var labels_buf: [max_tabs][]const u8 = undefined;
    const names = [_][]const u8{ "One", "Two", "Three", "Four", "Five", "Six" };
    for (0..count) |i| labels_buf[i] = names[i];
    return init(.{ .x = 10, .y = 20, .w = 120, .h = 200 }, labels_buf[0..count], selected);
}

test "tabAt divides the header strip into count equal columns (3 tabs)" {
    const t = testControl(3, 0);
    // header rect x=10..130, y=20..56 (height clamped to header_height=36), 3 tabs of width 40
    try std.testing.expectEqual(@as(?usize, 0), t.tabAt(15, 30));
    try std.testing.expectEqual(@as(?usize, 1), t.tabAt(60, 30));
    try std.testing.expectEqual(@as(?usize, 2), t.tabAt(125, 30));
}

test "tabAt returns null below the header strip (real panel content instead)" {
    const t = testControl(3, 0);
    // header strip ends at y=56 (20 + 36); y=100 is panel content territory
    try std.testing.expectEqual(@as(?usize, null), t.tabAt(15, 100));
}

test "tabAt returns null outside the rect" {
    const t = testControl(3, 0);
    try std.testing.expectEqual(@as(?usize, null), t.tabAt(5, 30));
    try std.testing.expectEqual(@as(?usize, null), t.tabAt(200, 30));
}

test "select clamps an out-of-range index to the last tab" {
    var t = testControl(3, 0);
    t.select(99);
    try std.testing.expectEqual(@as(usize, 2), t.selected_index);
}

test "init truncates labels over max_label_len and copies count correctly" {
    const long = "a" ** (max_label_len + 10);
    var t = init(.{ .x = 0, .y = 0, .w = 60, .h = 200 }, &.{ long, "ok" }, 1);
    try std.testing.expectEqual(@as(usize, 2), t.count);
    try std.testing.expectEqual(@as(usize, max_label_len), t.label_lens[0]);
    try std.testing.expectEqualStrings("ok", t.labelText(1));
    try std.testing.expectEqual(@as(usize, 1), t.selected_index);
}

test "headerRect clamps height to header_height even for a tall rect" {
    const t = testControl(2, 0);
    const hr = t.headerRect();
    try std.testing.expectEqual(@as(f32, header_height), hr.h);
    try std.testing.expectEqual(@as(f32, 10), hr.x);
    try std.testing.expectEqual(@as(f32, 20), hr.y);
}
