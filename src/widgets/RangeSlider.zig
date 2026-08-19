//! W27: a two-handle span selector -- distinct from `Slider` (W3), not just
//! "Slider with a second thumb bolted on". Selects a `[min, max]` span
//! instead of one value, which means two independently-draggable handles
//! share one `widget_id`: which handle a click/drag targets has to be
//! resolved (`closestHandle`), the handles can't cross (`setMin`/`setMax`
//! clamp against each other, not just against `[0, 1]`), and keyboard
//! nudging needs to know which handle to move (`active_handle`, updated on
//! every real click/drag -- see `main.zig`'s own doc comment on reusing
//! `dragging_slider_id` for this kind too). Same host-authoritative model as
//! Slider otherwise: value changes originate from a host-owned drag/nudge,
//! delivered to the guest as a `.change` event, not a guest `natyv_set_*`
//! call (though `natyv_set_range`/`natyv_get_range` still exist for a guest
//! to set/read a default, same "not the common case, but still works"
//! precedent Slider's own `natyv_set_value` support established).
//!
//! W27 follow-up (Quinn's real click-through feedback): the guest can
//! declare `step` at creation time -- both a drag and an arrow-key nudge
//! snap to the nearest multiple of it (see `snap`/`nudgeAmount`), unlike
//! Slider's own fixed, ungeneric `nudge_step`. `step <= 0` means
//! continuous (no snapping at all), the same behavior this widget had
//! before `step` existed.

const std = @import("std");
const c = @import("../c.zig").c;

const Self = @This();

/// Only used for keyboard nudging when `step <= 0` (continuous mode) --
/// arrow keys still need to move *some* fixed amount even with no real
/// step declared. Not otherwise guest-visible.
const default_nudge_step: f32 = 0.05;

pub const Handle = enum { min, max };

/// The full hit/drag target -- track, both thumbs, and focus ring are all
/// derived from this, same "whole rect is the click target" convention
/// Slider already uses.
rect: c.SDL_FRect,
/// Both clamped to `[0, 1]`, against each other (`min <= max` always), and
/// against `step` (if set) -- see `setMin`/`setMax`.
min: f32 = 0,
max: f32 = 1,
/// The guest-declared increment a drag or arrow-key nudge moves a handle
/// by -- `<= 0` means continuous (no snapping), the default. Same
/// normalized `[0, 1]` units as `min`/`max` themselves, not a real-world
/// domain unit (a guest wanting "$1 increments" on a $0-$50 span passes
/// `step = 1/50`, the same scaling its own display formatting already
/// does for `min`/`max` -- see the fixture's own `priceRange` demo).
step: f32 = 0,
/// Which handle the next arrow-key nudge moves, and which one a drag
/// currently in progress is moving -- set on every real click/drag-start
/// (`closestHandle`), not a separate sub-focus concept. Quinn's own call:
/// simplest model, reusing the existing single-`focused_widget_id`
/// mechanism instead of a Tab-cycling per-handle focus target.
active_handle: Handle = .min,
/// Keyboard interaction model: see Button.focused's doc comment. One flag
/// for the whole widget, same as Slider -- `active_handle` (above) is what
/// disambiguates which handle actually moves, not a second focus flag.
focused: bool = false,

pub fn init(rect: c.SDL_FRect, initial_min: f32, initial_max: f32, step: f32) Self {
    var self: Self = .{ .rect = rect, .step = step };
    // Order matters: clamp min against [0,1] first (max is still its
    // default 1, so min's own clamp can't be artificially narrowed), then
    // clamp max against whatever min ended up as -- same "min wins on
    // conflict" semantics setMin/setMax use everywhere else.
    self.setMin(initial_min);
    self.setMax(initial_max);
    return self;
}

/// Rounds `v` to the nearest multiple of `step`, clamped back to `[0, 1]`
/// -- a no-op when `step <= 0` (continuous mode). `@round` is monotonic
/// (never decreasing as its input increases), so snapping two already-
/// ordered values independently (as `setRangeHostFn`'s own `natyv_set_range`
/// handling does, one call setting both ends at once) can never invert
/// their order -- only `setMin`/`setMax` need the extra re-clamp their own
/// doc comments describe, for the single-handle-at-a-time drag/nudge case.
pub fn snap(self: Self, v: f32) f32 {
    if (self.step <= 0) return v;
    return std.math.clamp(@round(v / self.step) * self.step, 0, 1);
}

/// Clamped to `[0, max]` (not just `[0, 1]`) then snapped to `step` -- the
/// min handle can never cross the max handle (it stops exactly at it,
/// doesn't push it along). Re-clamped to `[0, max]` a second time *after*
/// snapping, since rounding to the nearest step can overshoot back past
/// whatever bound the first clamp just enforced (e.g. clamped to exactly
/// `max`, then rounded up past it).
pub fn setMin(self: *Self, v: f32) void {
    const clamped = std.math.clamp(v, 0, self.max);
    self.min = std.math.clamp(self.snap(clamped), 0, self.max);
}

/// Clamped to `[min, 1]` then snapped -- the max-handle counterpart to
/// `setMin`, same double-clamp-around-snap reasoning.
pub fn setMax(self: *Self, v: f32) void {
    const clamped = std.math.clamp(v, self.min, 1);
    self.max = std.math.clamp(self.snap(clamped), self.min, 1);
}

pub fn setHandleValue(self: *Self, handle: Handle, v: f32) void {
    switch (handle) {
        .min => self.setMin(v),
        .max => self.setMax(v),
    }
}

/// The current value of whichever handle `active_handle` names -- what an
/// arrow-key nudge (`main.zig`'s `SDLK_LEFT`/`RIGHT`/`DOWN`/`UP` handling)
/// adds/subtracts `nudgeAmount()` from.
pub fn activeValue(self: Self) f32 {
    return switch (self.active_handle) {
        .min => self.min,
        .max => self.max,
    };
}

/// How much one arrow-key press moves a focused handle -- `step` itself
/// when the guest declared one (keyboard and drag move by the same
/// increment, no separate notion of granularity), or `default_nudge_step`
/// in continuous mode.
pub fn nudgeAmount(self: Self) f32 {
    return if (self.step > 0) self.step else default_nudge_step;
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

fn thumbRectFor(self: Self, value: f32) c.SDL_FRect {
    const thumb_w = self.rect.h;
    return .{ .x = self.rect.x + value * (self.rect.w - thumb_w), .y = self.rect.y, .w = thumb_w, .h = self.rect.h };
}

pub fn minThumbRect(self: Self) c.SDL_FRect {
    return self.thumbRectFor(self.min);
}

pub fn maxThumbRect(self: Self) c.SDL_FRect {
    return self.thumbRectFor(self.max);
}

/// Pure inverse of `thumbRectFor`: the raw `[0, 1]` value whose thumb
/// *center* would land at `mouse_x` -- same math as `Slider.valueFromX`,
/// deliberately *not* clamped against the other handle here (that's
/// `setMin`/`setMax`'s job, called separately with whichever handle is
/// active). Drives click-to-jump and drag-follow alike, independently
/// testable without any SDL/mouse simulation.
pub fn valueFromX(self: Self, mouse_x: f32) f32 {
    const thumb_w = self.rect.h;
    const usable = self.rect.w - thumb_w;
    if (usable <= 0) return 0;
    const t = (mouse_x - self.rect.x - thumb_w / 2) / usable;
    return std.math.clamp(t, 0, 1);
}

/// Which handle a click/drag at `mouse_x` should target -- whichever
/// thumb's own center is closer. Exact ties (both thumbs at the same
/// position, e.g. `min == max`) go to `.min`, an arbitrary but deterministic
/// choice -- either handle would be equally correct there.
pub fn closestHandle(self: Self, mouse_x: f32) Handle {
    const min_center = self.minThumbRect().x + self.rect.h / 2;
    const max_center = self.maxThumbRect().x + self.rect.h / 2;
    return if (@abs(mouse_x - min_center) <= @abs(mouse_x - max_center)) .min else .max;
}

/// Thin centered track (background + filled span between the two thumbs,
/// same two-color custom draw `Slider`/`ProgressBar` already establish --
/// see `Widget.fillRect`'s doc comment for why this opts out of the batched
/// fill path) plus both thumb squares and a focus ring. The *active* handle
/// (whichever one the next arrow-key nudge would move) draws with the same
/// accent color as the filled span, so a keyboard user can tell which thumb
/// is "live" without needing to have just dragged it.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    const track_h: f32 = 4;
    const track: c.SDL_FRect = .{ .x = self.rect.x, .y = self.rect.y + self.rect.h / 2 - track_h / 2, .w = self.rect.w, .h = track_h };
    _ = c.SDL_SetRenderDrawColor(renderer, 45, 48, 58, 255);
    _ = c.SDL_RenderFillRect(renderer, &track);

    const min_thumb = self.minThumbRect();
    const max_thumb = self.maxThumbRect();
    const span_x = min_thumb.x + min_thumb.w / 2;
    const span_w = (max_thumb.x + max_thumb.w / 2) - span_x;
    if (span_w > 0) {
        _ = c.SDL_SetRenderDrawColor(renderer, 70, 140, 230, 255);
        const fill: c.SDL_FRect = .{ .x = span_x, .y = track.y, .w = span_w, .h = track.h };
        _ = c.SDL_RenderFillRect(renderer, &fill);
    }

    for ([2]struct { thumb: c.SDL_FRect, active: bool }{
        .{ .thumb = min_thumb, .active = self.active_handle == .min },
        .{ .thumb = max_thumb, .active = self.active_handle == .max },
    }) |entry| {
        if (entry.active) {
            _ = c.SDL_SetRenderDrawColor(renderer, 70, 140, 230, 255);
        } else {
            _ = c.SDL_SetRenderDrawColor(renderer, 200, 200, 210, 255);
        }
        _ = c.SDL_RenderFillRect(renderer, &entry.thumb);
        _ = c.SDL_SetRenderDrawColor(renderer, 140, 140, 150, 255);
        _ = c.SDL_RenderRect(renderer, &entry.thumb);
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

fn testRangeSlider(min: f32, max: f32) Self {
    return init(.{ .x = 10, .y = 20, .w = 100, .h = 20 }, min, max, 0);
}

fn testSteppedRangeSlider(min: f32, max: f32, step: f32) Self {
    return init(.{ .x = 10, .y = 20, .w = 100, .h = 20 }, min, max, step);
}

test "min thumb at 0 and max thumb at 1 sit at the track's edges" {
    const s = testRangeSlider(0, 1);
    const min_thumb = s.minThumbRect();
    const max_thumb = s.maxThumbRect();
    try std.testing.expectEqual(@as(f32, 10), min_thumb.x);
    try std.testing.expectEqual(@as(f32, 90), max_thumb.x);
    try std.testing.expectEqual(@as(f32, 110), max_thumb.x + max_thumb.w);
}

test "setMin cannot cross the current max -- clamps at max, doesn't push it" {
    var s = testRangeSlider(0.2, 0.6);
    s.setMin(0.9);
    try std.testing.expectEqual(@as(f32, 0.6), s.min);
    try std.testing.expectEqual(@as(f32, 0.6), s.max);
}

test "setMax cannot cross the current min -- clamps at min, doesn't push it" {
    var s = testRangeSlider(0.4, 0.7);
    s.setMax(0.1);
    try std.testing.expectEqual(@as(f32, 0.4), s.min);
    try std.testing.expectEqual(@as(f32, 0.4), s.max);
}

test "setMin/setMax still clamp to [0, 1] like Slider.setValue" {
    var s = testRangeSlider(0.3, 0.7);
    s.setMin(-1);
    try std.testing.expectEqual(@as(f32, 0), s.min);
    s.setMax(5);
    try std.testing.expectEqual(@as(f32, 1), s.max);
}

test "init clamps an out-of-order (min > max) initial pair against each other" {
    const s = testRangeSlider(0.8, 0.2);
    try std.testing.expectEqual(@as(f32, 0.8), s.min);
    try std.testing.expectEqual(@as(f32, 0.8), s.max);
}

test "valueFromX inverts thumbRectFor's center for several values" {
    inline for (.{ 0.0, 0.25, 0.5, 0.75, 1.0 }) |v| {
        const s = testRangeSlider(0, 1);
        const thumb = s.thumbRectFor(v);
        const center = thumb.x + thumb.w / 2;
        try std.testing.expectApproxEqAbs(@as(f32, v), s.valueFromX(center), 0.0001);
    }
}

test "closestHandle picks whichever thumb's center is nearer" {
    const s = testRangeSlider(0.2, 0.8);
    const min_center = s.minThumbRect().x + s.rect.h / 2;
    const max_center = s.maxThumbRect().x + s.rect.h / 2;
    try std.testing.expectEqual(Handle.min, s.closestHandle(min_center - 1));
    try std.testing.expectEqual(Handle.max, s.closestHandle(max_center + 1));
}

test "closestHandle ties (min == max) go to .min" {
    const s = testRangeSlider(0.5, 0.5);
    const center = s.minThumbRect().x + s.rect.h / 2;
    try std.testing.expectEqual(Handle.min, s.closestHandle(center));
}

test "setMin/setMax snap to the nearest multiple of step" {
    var s = testSteppedRangeSlider(0, 1, 0.1);
    s.setMin(0.23);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), s.min, 0.0001);
    s.setMax(0.77);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), s.max, 0.0001);
}

test "snapping never overshoots past the sibling handle it's clamped against" {
    // max set directly (not via setMax, which would itself snap it to the
    // grid) to a value NOT aligned to step -- simulates a sibling that
    // isn't grid-aligned (e.g. floating-point drift), the scenario the
    // post-snap re-clamp in setMin/setMax exists to guard against. step=0.1
    // would naturally round 0.36 up to 0.4, which must not cross max.
    var s = testSteppedRangeSlider(0, 1, 0.1);
    s.max = 0.35;
    s.setMin(0.36);
    try std.testing.expect(s.min <= s.max);
}

test "step <= 0 is continuous -- no snapping at all, same as before step existed" {
    var s = testSteppedRangeSlider(0, 1, 0);
    s.setMin(0.234);
    try std.testing.expectApproxEqAbs(@as(f32, 0.234), s.min, 0.0001);
}

test "nudgeAmount is step when declared, the default when continuous" {
    const stepped = testSteppedRangeSlider(0, 1, 0.2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), stepped.nudgeAmount(), 0.0001);
    const continuous = testRangeSlider(0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), continuous.nudgeAmount(), 0.0001);
}
