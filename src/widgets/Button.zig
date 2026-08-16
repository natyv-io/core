//! A clickable rectangle with a text label and a brief "pressed" flash for
//! click feedback. Native-drawn via SDL, no DOM/webview. Unlike the original
//! prototype, the label is guest-supplied at creation time (over the wire,
//! via natyv_create_button), so it's owned in a fixed buffer rather than a
//! static string literal.

const c = @import("../c.zig").c;
const timing = @import("../timing.zig");

const Self = @This();

const max_label_len = 127;

rect: c.SDL_FRect,
label_buf: [max_label_len + 1]u8 = undefined,
label_len: usize = 0,
flash_until_ms: i64 = 0,

pub fn init(rect: c.SDL_FRect, initial_label: []const u8) Self {
    var self: Self = .{ .rect = rect };
    self.setLabel(initial_label);
    return self;
}

pub fn setLabel(self: *Self, s: []const u8) void {
    const n = @min(s.len, max_label_len);
    @memcpy(self.label_buf[0..n], s[0..n]);
    self.label_buf[n] = 0;
    self.label_len = n;
}

pub fn label(self: *const Self) []const u8 {
    return self.label_buf[0..self.label_len];
}

fn labelZ(self: *const Self) [*:0]const u8 {
    return @ptrCast(&self.label_buf);
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

pub fn flash(self: *Self) void {
    self.flash_until_ms = timing.nowMs() + 150;
}

/// L4.5: the body fill is no longer drawn here -- main.zig's draw loop
/// buckets it (via `Widget.fillRect`) into a per-frame `DrawBatcher` and
/// fills it as part of one batched `SDL_RenderFillRects` call alongside
/// every other same-color widget, instead of its own
/// `SDL_SetRenderDrawColor`+`SDL_RenderFillRect` pair. This just picks
/// which color that fill should use.
pub fn fillColor(self: Self) c.SDL_Color {
    const flashing = timing.nowMs() < self.flash_until_ms;
    return if (flashing) .{ .r = 235, .g = 120, .b = 50, .a = 255 } else .{ .r = 60, .g = 65, .b = 80, .a = 255 };
}

/// Everything about a button that *isn't* a plain color fill -- drawn after
/// `DrawBatcher.flush` has painted every widget's fill for the frame, so
/// text always lands on top of an already-filled background.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    _ = c.SDL_RenderDebugText(renderer, self.rect.x + 10, self.rect.y + self.rect.h / 2 - 4, self.labelZ());
}
