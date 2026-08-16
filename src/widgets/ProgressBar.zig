//! A non-interactive horizontal fill indicator -- no focus, no click, no
//! text, same "pure display" treatment `Label`/`Container` already get
//! (excluded from hit-testing, hover, and Tab order entirely). Draws a
//! background track plus a `value`-scaled fill, both in `drawDecorations`
//! directly rather than through `Widget.fillRect`'s batching -- that helper
//! assumes one color per widget, and a progress bar inherently needs two
//! (track + fill) in the same rect. A fine tradeoff at the small quantities
//! progress bars actually appear in.

const c = @import("../c.zig").c;

const Self = @This();

rect: c.SDL_FRect,
/// Clamped to [0, 1] by `setValue` -- never stored out of range, so
/// `drawDecorations` never has to re-clamp before scaling the fill width.
value: f32 = 0,

pub fn init(rect: c.SDL_FRect, initial_value: f32) Self {
    var self: Self = .{ .rect = rect };
    self.setValue(initial_value);
    return self;
}

pub fn setValue(self: *Self, v: f32) void {
    self.value = @max(0, @min(1, v));
}

pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 45, 48, 58, 255);
    _ = c.SDL_RenderFillRect(renderer, &self.rect);

    if (self.value > 0) {
        _ = c.SDL_SetRenderDrawColor(renderer, 70, 140, 230, 255);
        const fill = c.SDL_FRect{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.w * self.value, .h = self.rect.h };
        _ = c.SDL_RenderFillRect(renderer, &fill);
    }
}
