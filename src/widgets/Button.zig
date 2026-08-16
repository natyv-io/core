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

pub fn draw(self: Self, renderer: ?*c.SDL_Renderer) void {
    const flashing = timing.nowMs() < self.flash_until_ms;
    if (flashing) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
    } else {
        _ = c.SDL_SetRenderDrawColor(renderer, 60, 65, 80, 255);
    }
    _ = c.SDL_RenderFillRect(renderer, &self.rect);

    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    _ = c.SDL_RenderDebugText(renderer, self.rect.x + 10, self.rect.y + self.rect.h / 2 - 4, self.labelZ());
}
