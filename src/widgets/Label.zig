//! Non-interactive text display -- no click handling, no focus, no flash.
//! Added in M5 once the bookstore guest needed to render its own book-list
//! rows (previously drawn directly by the host's main.zig via
//! SDL_RenderDebugText, which is exactly the kind of app-specific knowledge
//! the host isn't supposed to have anymore).
//!
//! W15 follow-up (surfaced by Quinn's real click-through of the Tooltip
//! demo, whose fixed copy is longer than the tooltip's 220px box): a Label
//! never wrapped its text to its own width -- it drew at whatever pixel
//! width the string naturally measures to, silently overflowing past its
//! Clay-assigned rect whenever content was longer than the box. Fixed the
//! same way TextArea.zig's own real word-wrap follow-up was: real
//! pixel-width wrap via `TTF_SetTextWrapWidth`, tracked against `rect.w`
//! through `wrapped_width` (see TextArea.syncText's doc comment for the
//! full "why not just set it once at creation" reasoning -- a Clay-managed
//! Label starts with a zeroed rect until the first real layout pass runs).

const std = @import("std");
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
// W15 follow-up: see TextArea.zig's field of the same name/purpose.
wrapped_width: i32 = -1,

pub fn init(rect: c.SDL_FRect, initial_text: []const u8) Self {
    var self: Self = .{ .rect = rect };
    _ = self.setText(initial_text);
    return self;
}

pub fn setText(self: *Self, s: []const u8) bool {
    const n = @min(s.len, max_text_len);
    if (self.len == n and std.mem.eql(u8, self.buf[0..n], s[0..n])) return false;
    @memcpy(self.buf[0..n], s[0..n]);
    self.buf[n] = 0;
    self.len = n;
    self.text_generation +%= 1;
    return true;
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
// Styling system Stage 2: drawn inset from `rect`'s top-left by the
// widget's own real padding (`WidgetHost.effectiveTextPadding`) instead of
// flush at `rect.x, rect.y` -- see that function's doc comment.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer, padding: c.Clay_Padding) void {
    _ = renderer;
    if (self.text_obj) |obj| {
        _ = c.TTF_DrawRendererText(obj, self.rect.x + @as(f32, @floatFromInt(padding.left)), self.rect.y + @as(f32, @floatFromInt(padding.top)));
    }
}

/// F3: see `Button.syncText`'s doc comment for the text-content sync shape.
/// W15 follow-up: see this file's own doc comment for the original
/// hardcoded-margin wrap-width tracking shape. Styling system Stage 2:
/// `padding` (already resolved via `WidgetHost.effectiveTextPadding` by the
/// caller) replaces that hardcoded `- 8` -- wrap width shrinks by the real
/// left+right padding instead of a fixed magic number.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font, padding: c.Clay_Padding) void {
    const target_wrap: i32 = @max(0, @as(i32, @intFromFloat(self.rect.w)) - @as(i32, padding.left) - @as(i32, padding.right));
    const wrap_changed = target_wrap != self.wrapped_width;

    // Real bug, found 2026-09-11: a genuinely empty Label (self.len == 0 --
    // e.g. `<Label ref={&x} />` with no text=, or setText("") applied to an
    // already-empty label, whose own equality short-circuit never bumps
    // generation) still reached SDL_ttf with a zero-length string and a
    // non-null pointer -- confirmed via direct evidence (temporary
    // diagnostic logging showed the real widget buffer was correctly empty
    // at the exact moment of creation, while the actual on-screen glyphs
    // were garbled, meaning corruption happens inside/after the SDL_ttf
    // call, not before it -- SDL_ttf does not cleanly handle this case).
    // Fix: never hand SDL_ttf a zero-length create/update at all. A
    // genuinely empty label needs no real TTF_Text object -- drawDecorations
    // already treats a null text_obj as "draw nothing," exactly correct
    // here -- and a label transitioning *to* empty gets its existing object
    // destroyed outright rather than "updated" with zero length.
    if (self.len == 0) {
        if (self.text_obj) |obj| {
            c.TTF_DestroyText(obj);
            self.text_obj = null;
        }
        self.text_obj_generation = self.text_generation;
    } else if (self.text_obj) |obj| {
        if (self.text_obj_generation != self.text_generation) {
            _ = c.TTF_SetTextString(obj, self.text().ptr, self.len);
            self.text_obj_generation = self.text_generation;
        }
        if (wrap_changed) _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
    } else if (c.TTF_CreateText(engine, font, self.text().ptr, self.len)) |obj| {
        _ = c.TTF_SetTextColor(obj, 220, 220, 220, 255);
        _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
        self.text_obj = obj;
        self.text_obj_generation = self.text_generation;
    }

    if (wrap_changed) self.wrapped_width = target_wrap;
}

/// Must be called before this widget is dropped from the registry -- see
/// `Button.destroyText`'s doc comment.
pub fn destroyText(self: *Self) void {
    if (self.text_obj) |obj| {
        c.TTF_DestroyText(obj);
        self.text_obj = null;
    }
}
