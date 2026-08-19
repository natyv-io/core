//! W29: a loading indicator -- the first widget in this project that
//! visually animates purely from wall-clock time (`timing.nowMs()`),
//! independent of any guest interaction or state change. Draws
//! `dot_count` dots in a horizontal row, each pulsing (radius growing/
//! shrinking) at a staggered phase, a "wave" loading effect -- no
//! interactivity, no guest-readable state, and deliberately no persisted
//! per-widget animation field at all: the phase is derived fresh from
//! wall-clock time inside `drawDecorations` on every call, which already
//! runs unconditionally every frame regardless of Clay's own layout
//! dirty-flag cache (confirmed against `ClayLayout.zig`'s own doc comment
//! on `layout_generation`: that cache only ever skips the layout
//! *recompute*, never the draw pass itself). So this needs no new host
//! mechanism beyond a plain Clay create function -- no tick/timer plumbing,
//! nothing for `main.zig`'s frame loop to drive.
//!
//! Real design fork (see widget_plan_small_atoms.md's own pre-implementation
//! draft): a true rotating arc needs hand-rolled line-segment geometry --
//! SDL3's `SDL_Renderer` has no native circle/arc primitive, only lines/
//! rects/points. Started with the simpler pulsing-dots version instead,
//! same recommendation that draft made; a true arc is a later/stretch item
//! if wanted, not a blocker for v1.
//!
//! Purely decorative like Divider/Badge: no text, no focus, not
//! hit-testable, no events -- doesn't need its own `containsPoint` at all,
//! since it never appears in any hit-test/hover switch.

const std = @import("std");
const c = @import("../c.zig").c;
const timing = @import("../timing.zig");

const Self = @This();

/// How many dots, evenly spaced across the widget's own width.
pub const dot_count: usize = 3;
/// One full pulse cycle, in milliseconds -- fixed, not guest-configurable
/// in v1, same treatment Slider's own `nudge_step`/Tooltip's hover-hold
/// threshold got.
pub const period_ms: i64 = 900;
/// A dot never shrinks past this fraction of its own full radius, so the
/// dimmest point of the cycle still reads as "there," not fully vanished.
const min_scale: f32 = 0.4;

rect: c.SDL_FRect,

pub fn init(rect: c.SDL_FRect) Self {
    return .{ .rect = rect };
}

/// dot `index`'s own radius scale in `[min_scale, 1]` at wall-clock time
/// `now_ms` -- pure function of time and index, independently testable
/// without any real draw call, same "geometry split out from the actual
/// SDL calls" precedent `ScrollBar.zig`/`Slider.zig` already establish.
/// Each dot is offset by `1/dot_count` of a full cycle from its neighbor,
/// producing a staggered wave rather than every dot pulsing in lockstep.
pub fn dotScale(now_ms: i64, index: usize) f32 {
    const t = @as(f32, @floatFromInt(@mod(now_ms, period_ms))) / @as(f32, @floatFromInt(period_ms));
    const phase_offset = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(dot_count));
    const phase = t + phase_offset;
    const wave = 0.5 + 0.5 * @sin(phase * std.math.pi * 2);
    return min_scale + (1 - min_scale) * wave;
}

/// L4.5: opts out of the single-color batched fill pass entirely, same
/// "this widget owns its whole draw" precedent Slider/Toggle/NumericStepper/
/// SegmentedControl/Tabs/RangeSlider already establish -- multiple
/// independently-scaled dots isn't a single solid-color rect.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    const now_ms = timing.nowMs();
    const base_radius = self.rect.h / 2;
    const gap = self.rect.h * 0.6;
    const total_w = @as(f32, @floatFromInt(dot_count - 1)) * (base_radius * 2 + gap) + base_radius * 2;
    const start_cx = self.rect.x + (self.rect.w - total_w) / 2 + base_radius;
    const cy = self.rect.y + self.rect.h / 2;

    _ = c.SDL_SetRenderDrawColor(renderer, 70, 140, 230, 255);
    for (0..dot_count) |i| {
        const r = base_radius * dotScale(now_ms, i);
        const cx = start_cx + @as(f32, @floatFromInt(i)) * (base_radius * 2 + gap);
        const dot: c.SDL_FRect = .{ .x = cx - r, .y = cy - r, .w = r * 2, .h = r * 2 };
        _ = c.SDL_RenderFillRect(renderer, &dot);
    }
}

test "dotScale stays within [min_scale, 1] across a full cycle" {
    var ms: i64 = 0;
    while (ms < period_ms) : (ms += 17) {
        for (0..dot_count) |i| {
            const s = dotScale(ms, i);
            try std.testing.expect(s >= min_scale - 0.0001 and s <= 1.0001);
        }
    }
}

test "dotScale peaks at 1.0 exactly a quarter-cycle before each dot's own phase origin" {
    // wave = 0.5 + 0.5*sin(phase*2pi) peaks (wave=1) when phase = 0.25 --
    // dot i's own phase is t + i/dot_count, so it peaks when
    // t = 0.25 - i/dot_count (mod 1).
    for (0..dot_count) |i| {
        const peak_t = @mod(0.25 - @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(dot_count)) + 1.0, 1.0);
        const now_ms: i64 = @intFromFloat(peak_t * @as(f32, @floatFromInt(period_ms)));
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), dotScale(now_ms, i), 0.01);
    }
}

test "adjacent dots are offset by exactly 1/dot_count of a cycle -- not pulsing in lockstep" {
    const now_ms: i64 = 100;
    const s0 = dotScale(now_ms, 0);
    const s1 = dotScale(now_ms, 1);
    const s2 = dotScale(now_ms, 2);
    // Same instant, three different phases -> generically three different
    // scales (not asserting exact values, just that they're not all equal,
    // which would indicate the phase offset silently isn't applying).
    try std.testing.expect(s0 != s1 or s1 != s2);
}

test "dotScale wraps correctly across a period boundary (time is cyclic, not monotonically increasing)" {
    // One full period later, at the same dot, must land on the exact same
    // scale -- the animation loops, it doesn't drift or reset oddly.
    const a = dotScale(500, 1);
    const b = dotScale(500 + period_ms, 1);
    try std.testing.expectApproxEqAbs(a, b, 0.001);
}
