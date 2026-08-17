//! W3: natyv's first host-authoritative interactive widget -- every other
//! kind (Checkbox/RadioButton/ProgressBar/TextField) changes state because
//! the guest called a `natyv_set_*` host function; a slider's value changes
//! because of a live mouse drag `main.zig` owns, and the guest finds out
//! *after the fact* via a "change" event (see EventQueue.zig), not by
//! initiating the change itself.
//!
//! No label/text in v1 -- same complexity tradeoff `ProgressBar` already
//! made (a label would need the full text_obj/syncText/destroyText
//! lifecycle for no functional gain here).

const std = @import("std");
const c = @import("../c.zig").c;

const Self = @This();

/// How much one Left/Right (or Up/Down) arrow-key press moves a focused
/// slider's value -- owned here, not hardcoded in main.zig, same
/// "constants live with the geometry they describe" precedent as
/// ScrollBar.thickness/.inset.
pub const nudge_step: f32 = 0.05;

/// The full hit/drag target -- track, thumb, and focus ring are all derived
/// from this, same "whole rect is the click target" convention Checkbox and
/// Button already use.
rect: c.SDL_FRect,
/// Clamped to [0, 1] by `setValue` -- never stored out of range, same
/// precedent as `ProgressBar.value`.
value: f32 = 0,
/// Keyboard interaction model: see Button.focused's doc comment.
focused: bool = false,

pub fn init(rect: c.SDL_FRect, initial_value: f32) Self {
    var self: Self = .{ .rect = rect };
    self.setValue(initial_value);
    return self;
}

pub fn setValue(self: *Self, v: f32) void {
    self.value = @max(0, @min(1, v));
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

/// The draggable knob -- a `rect.h`-square, same "square from height"
/// convention `Checkbox.boxRect` uses. Confined entirely inside `rect`:
/// reaches exactly the left edge at value 0 and the right edge at value 1,
/// never overhanging either side.
pub fn thumbRect(self: Self) c.SDL_FRect {
    const thumb_w = self.rect.h;
    return .{ .x = self.rect.x + self.value * (self.rect.w - thumb_w), .y = self.rect.y, .w = thumb_w, .h = self.rect.h };
}

/// Pure inverse of `thumbRect`: the value whose thumb *center* would land
/// at `mouse_x`, clamped to [0, 1]. Drives click-to-jump and drag-follow
/// alike (see main.zig's per-frame drag-update block) and is independently
/// testable without any SDL/mouse simulation -- same "pure geometry,
/// unit-tested directly" split ScrollBar.zig established for W2.
pub fn valueFromX(self: Self, mouse_x: f32) f32 {
    const thumb_w = self.rect.h;
    const usable = self.rect.w - thumb_w;
    if (usable <= 0) return 0;
    const t = (mouse_x - self.rect.x - thumb_w / 2) / usable;
    return std.math.clamp(t, 0, 1);
}

/// Thin centered track (background + filled portion up to the thumb,
/// ProgressBar-style two-color custom draw -- see `Widget.fillRect`'s
/// doc comment for why this opts out of the batched fill path the same way
/// ProgressBar does) plus the thumb square and a focus ring.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    const track_h: f32 = 4;
    const track: c.SDL_FRect = .{ .x = self.rect.x, .y = self.rect.y + self.rect.h / 2 - track_h / 2, .w = self.rect.w, .h = track_h };
    _ = c.SDL_SetRenderDrawColor(renderer, 45, 48, 58, 255);
    _ = c.SDL_RenderFillRect(renderer, &track);

    const thumb = self.thumbRect();
    const fill_w = thumb.x + thumb.w / 2 - track.x;
    if (fill_w > 0) {
        _ = c.SDL_SetRenderDrawColor(renderer, 70, 140, 230, 255);
        const fill: c.SDL_FRect = .{ .x = track.x, .y = track.y, .w = fill_w, .h = track.h };
        _ = c.SDL_RenderFillRect(renderer, &fill);
    }

    _ = c.SDL_SetRenderDrawColor(renderer, 200, 200, 210, 255);
    _ = c.SDL_RenderFillRect(renderer, &thumb);
    _ = c.SDL_SetRenderDrawColor(renderer, 140, 140, 150, 255);
    _ = c.SDL_RenderRect(renderer, &thumb);

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

fn testSlider(value: f32) Self {
    return init(.{ .x = 10, .y = 20, .w = 100, .h = 20 }, value);
}

test "thumb at value 0 sits at the track's left edge" {
    const s = testSlider(0);
    const thumb = s.thumbRect();
    try std.testing.expectEqual(@as(f32, 10), thumb.x);
    try std.testing.expectEqual(@as(f32, 20), thumb.w);
}

test "thumb at value 1 sits at the track's right edge" {
    const s = testSlider(1);
    const thumb = s.thumbRect();
    // rect.w=100, thumb_w=20 -> usable=80 -> x = 10 + 1*80 = 90, right edge at 110 = rect right edge.
    try std.testing.expectEqual(@as(f32, 90), thumb.x);
    try std.testing.expectEqual(@as(f32, 110), thumb.x + thumb.w);
}

test "thumb at value 0.5 sits at the horizontal midpoint of available travel" {
    const s = testSlider(0.5);
    const thumb = s.thumbRect();
    try std.testing.expectEqual(@as(f32, 50), thumb.x); // 10 + 0.5*80
}

test "valueFromX inverts thumbRect's center for several values" {
    inline for (.{ 0.0, 0.25, 0.5, 0.75, 1.0 }) |v| {
        const s = testSlider(v);
        const thumb = s.thumbRect();
        const center = thumb.x + thumb.w / 2;
        try std.testing.expectApproxEqAbs(@as(f32, v), s.valueFromX(center), 0.0001);
    }
}

test "valueFromX clamps mouse positions outside the track to [0, 1]" {
    const s = testSlider(0.5);
    try std.testing.expectEqual(@as(f32, 0), s.valueFromX(-1000));
    try std.testing.expectEqual(@as(f32, 1), s.valueFromX(1000));
}

test "valueFromX returns 0 defensively when the track is narrower than the thumb" {
    const s = init(.{ .x = 0, .y = 0, .w = 10, .h = 20 }, 0);
    try std.testing.expectEqual(@as(f32, 0), s.valueFromX(5));
}

test "setValue clamps out-of-range input like ProgressBar" {
    var s = testSlider(0.5);
    s.setValue(-1);
    try std.testing.expectEqual(@as(f32, 0), s.value);
    s.setValue(5);
    try std.testing.expectEqual(@as(f32, 1), s.value);
}
