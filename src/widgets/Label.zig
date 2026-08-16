//! Non-interactive text display -- no click handling, no focus, no flash.
//! Added in M5 once the bookstore guest needed to render its own book-list
//! rows (previously drawn directly by the host's main.zig via
//! SDL_RenderDebugText, which is exactly the kind of app-specific knowledge
//! the host isn't supposed to have anymore).

const c = @import("../c.zig").c;

const Self = @This();

const max_text_len = 255;

rect: c.SDL_FRect,
buf: [max_text_len + 1]u8 = undefined,
len: usize = 0,

pub fn init(rect: c.SDL_FRect, initial_text: []const u8) Self {
    var self: Self = .{ .rect = rect };
    self.setText(initial_text);
    return self;
}

pub fn setText(self: *Self, s: []const u8) void {
    const n = @min(s.len, max_text_len);
    @memcpy(self.buf[0..n], s[0..n]);
    self.buf[n] = 0;
    self.len = n;
}

pub fn text(self: *const Self) []const u8 {
    return self.buf[0..self.len];
}

fn textZ(self: *const Self) [*:0]const u8 {
    return @ptrCast(&self.buf);
}

// L4.5: a Label has no fill of its own (never did) -- renamed to
// `drawDecorations` purely so main.zig can call the same method name
// across every drawable widget kind after DrawBatcher.flush, not because
// anything about what a Label draws changed.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    _ = c.SDL_SetRenderDrawColor(renderer, 220, 220, 220, 255);
    _ = c.SDL_RenderDebugText(renderer, self.rect.x, self.rect.y, self.textZ());
}
