//! One option in a mutually-exclusive group -- same shape as `Checkbox`
//! (box + optional label, focusable, keyboard-activatable) but selecting
//! one radio button deselects every other radio button sharing its
//! `group_id`. The exclusivity logic itself lives in
//! `WidgetHost.selectRadioExclusive` (it needs to reach across the whole
//! registry, not just this widget), not here -- this file only knows how to
//! become selected (`select`), not how to deselect its siblings.
//!
//! `group_id` is an arbitrary tag the guest picks at creation time --
//! deliberately not derived from `parent_id`, since `parent_id` is only
//! meaningful for Clay-managed widgets and would silently break grouping
//! for a plain absolute-pixel app.
//!
//! Styling system Stage 3 (post-pivot): the box is a genuine circle now,
//! not the square-box-reused-for-radio placeholder this file's own doc
//! comment used to describe -- drawn via `ShapeCache`'s tessellate +
//! 4x-supersample + cache masks (ShapeCache.zig's own doc comment has the
//! full technique and why it replaced the earlier SDF shader attempt). The
//! ring uses `border_width = 2`; the checked dot is a plain filled circle
//! inset from the box.

const c = @import("../c.zig").c;
const ShapeCache = @import("../capabilities/ShapeCache.zig");

const Self = @This();

const max_label_len = 127;
const label_gap = 8;

rect: c.SDL_FRect,
checked: bool = false,
group_id: u32 = 0,
label_buf: [max_label_len + 1]u8 = undefined,
label_len: usize = 0,
text_obj: ?*c.TTF_Text = null,
text_generation: u32 = 0,
text_obj_generation: u32 = 0,
sync_count: u32 = 0,
focused: bool = false,

pub fn init(rect: c.SDL_FRect, group_id: u32, initial_label: []const u8) Self {
    var self: Self = .{ .rect = rect, .group_id = group_id };
    self.setLabel(initial_label);
    return self;
}

pub fn setLabel(self: *Self, s: []const u8) void {
    const n = @min(s.len, max_label_len);
    @memcpy(self.label_buf[0..n], s[0..n]);
    self.label_buf[n] = 0;
    self.label_len = n;
    self.text_generation +%= 1;
}

pub fn label(self: *const Self) []const u8 {
    return self.label_buf[0..self.label_len];
}

pub fn boxRect(self: Self) c.SDL_FRect {
    return .{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.h, .h = self.rect.h };
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

/// Just becomes selected -- deselecting siblings in the same group is
/// `WidgetHost.selectRadioExclusive`'s job, not this widget's own.
pub fn select(self: *Self) void {
    self.checked = true;
}

pub fn deselect(self: *Self) void {
    self.checked = false;
}

/// Unlike `Checkbox` (whole box fills solid when checked, batched via
/// `Widget.fillRect`), a selected radio button only fills a small *inset*
/// dot -- not the whole box -- so it doesn't fit that one-solid-color-per-
/// widget batching model at all. `Widget.fillRect` returns `null` for
/// `.radio_button` and everything (outline + dot) is drawn directly here
/// instead, the same "opt out of batching" treatment `ProgressBar` uses for
/// its own two-color-per-widget case.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer, shape_cache: *ShapeCache.Cache) void {
    const box = self.boxRect();
    ShapeCache.drawRing(shape_cache, renderer, box, 2, .{ .r = 140, .g = 140, .b = 150, .a = 255 });

    if (self.checked) {
        const inset = box.w * 0.3;
        const dot = c.SDL_FRect{ .x = box.x + inset / 2, .y = box.y + inset / 2, .w = box.w - inset, .h = box.h - inset };
        ShapeCache.drawCircle(shape_cache, renderer, dot, .{ .r = 150, .g = 100, .b = 220, .a = 255 });
    }

    if (self.text_obj) |obj| {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetTextSize(obj, &w, &h);
        _ = c.TTF_DrawRendererText(obj, self.rect.x + self.rect.h + label_gap, self.rect.y + self.rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

/// See `Button.syncText`'s doc comment -- identical shape.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
    if (self.text_obj) |obj| {
        if (self.text_obj_generation != self.text_generation) {
            _ = c.TTF_SetTextString(obj, self.label().ptr, self.label_len);
            self.text_obj_generation = self.text_generation;
            self.sync_count += 1;
        }
    } else if (c.TTF_CreateText(engine, font, self.label().ptr, self.label_len)) |obj| {
        _ = c.TTF_SetTextColor(obj, 255, 255, 255, 255);
        self.text_obj = obj;
        self.text_obj_generation = self.text_generation;
        self.sync_count += 1;
    }
}

/// See `Button.destroyText`'s doc comment.
pub fn destroyText(self: *Self) void {
    if (self.text_obj) |obj| {
        c.TTF_DestroyText(obj);
        self.text_obj = null;
    }
}
