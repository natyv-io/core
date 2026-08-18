//! W17: natyv's first widget with more than one independently-clickable
//! zone inside a single rect -- every prior widget (Button, Slider, ...)
//! hit-tests as one whole-rect target; a stepper has a minus zone, a value
//! display, and a plus zone, and needs to tell them apart (see `regionAt`).
//!
//! Host-authoritative like `Slider` (W3): the value changes because
//! `main.zig` handled a click or an arrow-key press, not because the guest
//! called a `natyv_set_*` function, and the guest finds out after the fact
//! via a "change" event. Integer-valued (unlike Slider's normalized 0..1
//! `f32`) with `min`/`max`/`step`/`wrap`, since this exists specifically to
//! replace the Date & time picker's (W16) hour/minute controls, which need
//! real wraparound (hour 23 -> 0, minute 55 -> 0), not clamping.

const std = @import("std");
const c = @import("../c.zig").c;

const Self = @This();

const max_value_len = 15;

rect: c.SDL_FRect,
value: i32,
min: i32,
max: i32,
step: i32 = 1,
/// true wraps past `min`/`max` back around to the other end (the picker's
/// hour/minute use case); false clamps at the ends (the common "quantity
/// picker" case). See `resolve`.
wrap: bool = false,
/// Keyboard interaction model: see Button.focused's doc comment.
focused: bool = false,

// F3-style cached TTF_Text handle for the centered value display -- see
// Badge.zig's fields of the same name/purpose for the full explanation.
// The minus/plus zone glyphs are drawn as plain vector lines (see
// `drawDecorations`), not text, so this is the widget's only `TTF_Text`.
value_buf: [max_value_len + 1]u8 = undefined,
value_len: usize = 0,
text_obj: ?*c.TTF_Text = null,
text_generation: u32 = 0,
text_obj_generation: u32 = 0,
sync_count: u32 = 0,

pub fn init(rect: c.SDL_FRect, initial_value: i32, min: i32, max: i32, step: i32, wrap: bool) Self {
    var self: Self = .{ .rect = rect, .value = initial_value, .min = min, .max = max, .step = step, .wrap = wrap };
    self.setValue(initial_value);
    return self;
}

/// Pure clamp/wrap logic, independently testable without touching
/// `self.value` -- same "pure geometry, unit-tested directly" split
/// `Slider.valueFromX` already established. `wrap` requires `max >= min`
/// (always true for any real stepper); Zig's `@mod` is floored (sign
/// follows the divisor), so `v - min` mod a positive `range` always lands
/// in `[0, range)` regardless of which direction `v` under/overshot by.
pub fn resolve(self: Self, v: i32) i32 {
    if (self.wrap) {
        const range = self.max - self.min + 1;
        return self.min + @mod(v - self.min, range);
    }
    return std.math.clamp(v, self.min, self.max);
}

pub fn setValue(self: *Self, v: i32) void {
    self.value = self.resolve(v);
    const s = std.fmt.bufPrint(&self.value_buf, "{d}", .{self.value}) catch "?";
    self.value_len = s.len;
    self.text_generation +%= 1;
}

fn valueText(self: *const Self) []const u8 {
    return self.value_buf[0..self.value_len];
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

pub const Region = enum { none, minus, plus };

/// Splits `rect` into a minus zone on the left, a plus zone on the right
/// (each `rect.h` wide -- "square from height," same convention
/// `Slider.thumbRect`/`Checkbox.boxRect` already use), and a middle no-op
/// zone showing the value. Returns `.none` outside `rect` entirely, or if
/// the two zones would overlap (a degenerately narrow rect).
pub fn regionAt(self: Self, x: f32, y: f32) Region {
    if (!self.containsPoint(x, y)) return .none;
    const zone_w = self.rect.h;
    if (zone_w * 2 >= self.rect.w) return .none;
    if (x < self.rect.x + zone_w) return .minus;
    if (x >= self.rect.x + self.rect.w - zone_w) return .plus;
    return .none;
}

/// Whole-widget background plus the minus/plus zone borders and glyphs
/// (drawn as plain vector lines, not text -- see the file doc comment) and
/// the centered value text. Opts out of the single-color batched fill the
/// same way `Slider`/`Toggle` do (see `Widget.fillRect`'s doc comment),
/// since this is a multi-region custom draw, not one solid color.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 60, 65, 80, 255);
    _ = c.SDL_RenderFillRect(renderer, &self.rect);

    const zone_w = self.rect.h;
    const minus_rect: c.SDL_FRect = .{ .x = self.rect.x, .y = self.rect.y, .w = zone_w, .h = self.rect.h };
    const plus_rect: c.SDL_FRect = .{ .x = self.rect.x + self.rect.w - zone_w, .y = self.rect.y, .w = zone_w, .h = self.rect.h };
    _ = c.SDL_SetRenderDrawColor(renderer, 140, 140, 150, 255);
    _ = c.SDL_RenderRect(renderer, &minus_rect);
    _ = c.SDL_RenderRect(renderer, &plus_rect);

    _ = c.SDL_SetRenderDrawColor(renderer, 220, 220, 225, 255);
    const glyph_inset: f32 = 6;
    const minus_y = minus_rect.y + minus_rect.h / 2;
    _ = c.SDL_RenderLine(renderer, minus_rect.x + glyph_inset, minus_y, minus_rect.x + minus_rect.w - glyph_inset, minus_y);
    const plus_mid_x = plus_rect.x + plus_rect.w / 2;
    const plus_mid_y = plus_rect.y + plus_rect.h / 2;
    _ = c.SDL_RenderLine(renderer, plus_rect.x + glyph_inset, plus_mid_y, plus_rect.x + plus_rect.w - glyph_inset, plus_mid_y);
    _ = c.SDL_RenderLine(renderer, plus_mid_x, plus_rect.y + glyph_inset, plus_mid_x, plus_rect.y + plus_rect.h - glyph_inset);

    if (self.text_obj) |obj| {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetTextSize(obj, &w, &h);
        _ = c.TTF_DrawRendererText(obj, self.rect.x + self.rect.w / 2 - @as(f32, @floatFromInt(w)) / 2, self.rect.y + self.rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

/// See `Button.syncText`'s doc comment -- identical shape, over `valueText()`
/// instead of a guest-supplied label.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
    if (self.text_obj) |obj| {
        if (self.text_obj_generation != self.text_generation) {
            _ = c.TTF_SetTextString(obj, self.valueText().ptr, self.value_len);
            self.text_obj_generation = self.text_generation;
            self.sync_count += 1;
        }
    } else if (c.TTF_CreateText(engine, font, self.valueText().ptr, self.value_len)) |obj| {
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

fn testStepper(value: i32, min: i32, max: i32, wrap: bool) Self {
    return init(.{ .x = 10, .y = 20, .w = 100, .h = 24 }, value, min, max, 1, wrap);
}

test "regionAt: left zone is minus, right zone is plus, middle is none" {
    const s = testStepper(5, 0, 10, false);
    try std.testing.expectEqual(Region.minus, s.regionAt(15, 30));
    try std.testing.expectEqual(Region.plus, s.regionAt(95, 30));
    try std.testing.expectEqual(Region.none, s.regionAt(60, 30));
}

test "regionAt: outside the rect entirely is none" {
    const s = testStepper(5, 0, 10, false);
    try std.testing.expectEqual(Region.none, s.regionAt(5, 30));
    try std.testing.expectEqual(Region.none, s.regionAt(115, 30));
    try std.testing.expectEqual(Region.none, s.regionAt(50, 10));
}

test "regionAt: degenerately narrow rect (zones would overlap) is always none" {
    const s = init(.{ .x = 0, .y = 0, .w = 30, .h = 24 }, 0, 0, 10, 1, false);
    try std.testing.expectEqual(Region.none, s.regionAt(15, 10));
}

test "resolve clamps at min/max when wrap is false" {
    const s = testStepper(5, 0, 10, false);
    try std.testing.expectEqual(@as(i32, 10), s.resolve(15));
    try std.testing.expectEqual(@as(i32, 0), s.resolve(-5));
}

test "resolve wraps past max back to min (hour 23 -> 0 case)" {
    const s = testStepper(23, 0, 23, true);
    try std.testing.expectEqual(@as(i32, 0), s.resolve(24));
}

test "resolve wraps past min back to max (hour 0 -> 23 case)" {
    const s = testStepper(0, 0, 23, true);
    try std.testing.expectEqual(@as(i32, 23), s.resolve(-1));
}

// Minute wraparound needs `max: 59` (a full 0-59 minute range), not 55 --
// `resolve` wraps modulo `max - min + 1`, so a `max` of 55 would wrap
// modulo 56, not the 60 real minute-of-hour arithmetic needs. The guest
// only ever *lands* on multiples of 5 (creates the stepper at a multiple
// of 5, steps by 5), but the logical valid range is still the full hour.
test "resolve wraps minute stepping by 5 past 59 back to 0" {
    const s = testStepper(55, 0, 59, true);
    try std.testing.expectEqual(@as(i32, 0), s.resolve(60));
}

test "setValue updates the formatted value text and bumps generation" {
    var s = testStepper(5, 0, 10, false);
    const gen_before = s.text_generation;
    s.setValue(7);
    try std.testing.expectEqual(@as(i32, 7), s.value);
    try std.testing.expectEqualStrings("7", s.valueText());
    try std.testing.expect(s.text_generation != gen_before);
}
