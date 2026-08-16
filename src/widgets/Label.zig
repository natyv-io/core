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
// F3: see Button.zig's fields of the same name/purpose.
text_obj: ?*c.TTF_Text = null,
text_generation: u32 = 0,
text_obj_generation: u32 = 0,

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
    self.text_generation +%= 1;
}

pub fn text(self: *const Self) []const u8 {
    return self.buf[0..self.len];
}

// L4.5: a Label has no fill of its own (never did) -- renamed to
// `drawDecorations` purely so main.zig can call the same method name
// across every drawable widget kind after DrawBatcher.flush, not because
// anything about what a Label draws changed.
//
// F3: draws the real `text_obj` kept in sync by `syncText` -- see
// `Button.drawDecorations`'s doc comment for why creation can't happen here.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    _ = renderer;
    if (self.text_obj) |obj| {
        _ = c.TTF_DrawRendererText(obj, self.rect.x, self.rect.y);
    }
}

/// F3: see `Button.syncText`'s doc comment.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
    if (self.text_obj) |obj| {
        if (self.text_obj_generation != self.text_generation) {
            _ = c.TTF_SetTextString(obj, self.text().ptr, self.len);
            self.text_obj_generation = self.text_generation;
        }
    } else if (c.TTF_CreateText(engine, font, self.text().ptr, self.len)) |obj| {
        _ = c.TTF_SetTextColor(obj, 220, 220, 220, 255);
        self.text_obj = obj;
        self.text_obj_generation = self.text_generation;
    }
}

/// Must be called before this widget is dropped from the registry -- see
/// `Button.destroyText`'s doc comment.
pub fn destroyText(self: *Self) void {
    if (self.text_obj) |obj| {
        c.TTF_DestroyText(obj);
        self.text_obj = null;
    }
}
