//! A single-line text input box. Native-drawn via SDL, focused by clicking
//! inside it; while focused, receives SDL_EVENT_TEXT_INPUT for typed
//! characters and backspace via SDL_EVENT_KEY_DOWN. Placeholder is
//! guest-supplied at creation; content is host-owned (typed by the user) but
//! readable/settable by the guest via natyv_get_text/natyv_set_text.

const c = @import("../c.zig").c;

const Self = @This();

pub const max_len = 127;
const max_placeholder_len = 63;

rect: c.SDL_FRect,
placeholder_buf: [max_placeholder_len + 1]u8 = undefined,
placeholder_len: usize = 0,
buf: [max_len + 1]u8 = undefined,
len: usize = 0,
focused: bool = false,
// F3: two separate TTF_Text handles -- entered text and placeholder are
// drawn as alternatives (never both), but keeping them as distinct objects
// lets each carry its own persistent color (white vs. gray) set once at
// creation, matching what the old SDL_RenderDebugText path did per-call.
// placeholder_obj never needs re-syncing after creation: `setPlaceholder`
// is only ever called once, from `init` (see its doc comment).
text_obj: ?*c.TTF_Text = null,
text_generation: u32 = 0,
text_obj_generation: u32 = 0,
placeholder_obj: ?*c.TTF_Text = null,

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

pub fn text(self: *const Self) []const u8 {
    return self.buf[0..self.len];
}

pub fn setText(self: *Self, s: []const u8) void {
    const n = @min(s.len, max_len);
    @memcpy(self.buf[0..n], s[0..n]);
    self.len = n;
    self.text_generation +%= 1;
}

pub fn clear(self: *Self) void {
    self.len = 0;
    self.text_generation +%= 1;
}

pub fn appendText(self: *Self, s: []const u8) void {
    const room = max_len - self.len;
    const n = @min(room, s.len);
    @memcpy(self.buf[self.len..][0..n], s[0..n]);
    self.len += n;
    self.text_generation +%= 1;
}

pub fn backspace(self: *Self) void {
    if (self.len == 0) return;
    var i = self.len - 1;
    // Step back over one UTF-8 codepoint, not just one byte.
    while (i > 0 and (self.buf[i] & 0xC0) == 0x80) : (i -= 1) {}
    self.len = i;
    self.text_generation +%= 1;
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

/// F3: draws entered text if any, else the placeholder -- same either/or
/// as before, now against real `TTF_Text` objects kept in sync by
/// `syncText` (see `Button.drawDecorations`'s doc comment for why creation
/// can't happen here).
// Styling system Stage 2: horizontal offset is the widget's own real
// padding (`WidgetHost.effectiveTextPadding`) instead of the original
// hardcoded `+ 6`.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer, padding: c.Clay_Padding) void {
    const active = if (self.len > 0) self.text_obj else self.placeholder_obj;
    if (active) |obj| {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetTextSize(obj, &w, &h);
        _ = c.TTF_DrawRendererText(obj, self.rect.x + @as(f32, @floatFromInt(padding.left)), self.rect.y + self.rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

/// F3: see `Button.syncText`'s doc comment -- same generation-counter
/// shape for the entered-text object. `placeholder_obj` is create-once
/// only: `setPlaceholder` is never called after `init`, so there's nothing
/// to ever re-sync it against.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
    if (self.text_obj) |obj| {
        if (self.text_obj_generation != self.text_generation) {
            _ = c.TTF_SetTextString(obj, self.text().ptr, self.len);
            self.text_obj_generation = self.text_generation;
        }
    } else if (c.TTF_CreateText(engine, font, self.text().ptr, self.len)) |obj| {
        _ = c.TTF_SetTextColor(obj, 255, 255, 255, 255);
        self.text_obj = obj;
        self.text_obj_generation = self.text_generation;
    }

    if (self.placeholder_obj == null) {
        if (c.TTF_CreateText(engine, font, self.placeholder().ptr, self.placeholder_len)) |obj| {
            _ = c.TTF_SetTextColor(obj, 120, 120, 130, 255);
            self.placeholder_obj = obj;
        }
    }
}

/// Must be called before this widget is dropped from the registry -- see
/// `Button.destroyText`'s doc comment.
pub fn destroyText(self: *Self) void {
    if (self.text_obj) |obj| {
        c.TTF_DestroyText(obj);
        self.text_obj = null;
    }
    if (self.placeholder_obj) |obj| {
        c.TTF_DestroyText(obj);
        self.placeholder_obj = null;
    }
}
