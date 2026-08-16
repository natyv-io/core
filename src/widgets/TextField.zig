//! A single-line text input box. Native-drawn via SDL, focused by clicking
//! inside it; while focused, receives SDL_EVENT_TEXT_INPUT for typed
//! characters and backspace via SDL_EVENT_KEY_DOWN. Placeholder is
//! guest-supplied at creation; content is host-owned (typed by the user) but
//! readable/settable by the guest via natyv_get_text/natyv_set_text.

const c = @import("../c.zig").c;

const Self = @This();

const max_len = 127;
const max_placeholder_len = 63;

rect: c.SDL_FRect,
placeholder_buf: [max_placeholder_len + 1]u8 = undefined,
placeholder_len: usize = 0,
buf: [max_len + 1]u8 = undefined,
len: usize = 0,
focused: bool = false,

pub fn init(rect: c.SDL_FRect, initial_placeholder: []const u8) Self {
    var self: Self = .{ .rect = rect };
    self.setPlaceholder(initial_placeholder);
    return self;
}

pub fn setPlaceholder(self: *Self, s: []const u8) void {
    const n = @min(s.len, max_placeholder_len);
    @memcpy(self.placeholder_buf[0..n], s[0..n]);
    self.placeholder_buf[n] = 0;
    self.placeholder_len = n;
}

pub fn placeholder(self: *const Self) []const u8 {
    return self.placeholder_buf[0..self.placeholder_len];
}

fn placeholderZ(self: *const Self) [*:0]const u8 {
    return @ptrCast(&self.placeholder_buf);
}

pub fn text(self: *const Self) []const u8 {
    return self.buf[0..self.len];
}

pub fn setText(self: *Self, s: []const u8) void {
    const n = @min(s.len, max_len);
    @memcpy(self.buf[0..n], s[0..n]);
    self.len = n;
}

pub fn clear(self: *Self) void {
    self.len = 0;
}

pub fn appendText(self: *Self, s: []const u8) void {
    const room = max_len - self.len;
    const n = @min(room, s.len);
    @memcpy(self.buf[self.len..][0..n], s[0..n]);
    self.len += n;
}

pub fn backspace(self: *Self) void {
    if (self.len == 0) return;
    var i = self.len - 1;
    // Step back over one UTF-8 codepoint, not just one byte.
    while (i > 0 and (self.buf[i] & 0xC0) == 0x80) : (i -= 1) {}
    self.len = i;
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

/// L4.5: see Button.fillColor's doc comment -- same split, same reason.
pub fn fillColor(self: Self) c.SDL_Color {
    return if (self.focused)
        .{ .r = 80, .g = 90, .b = 110, .a = 255 }
    else
        .{ .r = 45, .g = 48, .b = 58, .a = 255 };
}

pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    const text_y = self.rect.y + self.rect.h / 2 - 4;
    if (self.len > 0) {
        var buf: [max_len + 1]u8 = undefined;
        @memcpy(buf[0..self.len], self.buf[0..self.len]);
        buf[self.len] = 0;
        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
        _ = c.SDL_RenderDebugText(renderer, self.rect.x + 6, text_y, @ptrCast(&buf));
    } else {
        _ = c.SDL_SetRenderDrawColor(renderer, 120, 120, 130, 255);
        _ = c.SDL_RenderDebugText(renderer, self.rect.x + 6, text_y, self.placeholderZ());
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}
