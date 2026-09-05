//! W10: a multi-line text input box. Native-drawn via SDL, focused by
//! clicking inside it; while focused, receives SDL_EVENT_TEXT_INPUT for
//! typed characters, backspace via SDL_EVENT_KEY_DOWN, and Enter inserts a
//! literal newline (unlike TextField, where Enter means "select the
//! highlighted combobox option" instead -- see main.zig's SDLK_RETURN
//! handling). Placeholder is guest-supplied at creation; content is
//! host-owned (typed by the user) but readable/settable by the guest via
//! natyv_get_text/natyv_set_text.
//!
//! Deliberately mirrors TextField.zig's shape closely -- same append/
//! backspace-at-the-end-only model (no arbitrary cursor position; neither
//! widget has ever needed one), same generation-counter TTF_Text sync
//! pattern. The two real differences: a much larger buffer (this is meant
//! to hold several paragraphs, not one line), and top-left (not vertically
//! centered) text anchoring with real pixel-width word-wrap, tracked
//! against the widget's own rect.w (see syncText) -- a line that reaches
//! the box's edge drops to the next line, same as embedded `\n` bytes
//! already do. Vertical scrolling for content past the box's height is
//! still deferred (see drawDecorations) -- only clipped, not scrollable,
//! for now.

const std = @import("std");
const c = @import("../c.zig").c;

const Self = @This();

pub const max_len = 1023;
const max_placeholder_len = 63;

rect: c.SDL_FRect,
placeholder_buf: [max_placeholder_len + 1]u8 = undefined,
placeholder_len: usize = 0,
buf: [max_len + 1]u8 = undefined,
len: usize = 0,
focused: bool = false,
// F3: two separate TTF_Text handles -- entered text and placeholder are
// drawn as alternatives (never both), same split TextField.zig uses and
// for the same reason (each carries its own persistent color, set once).
// placeholder_obj never needs re-syncing after creation: setPlaceholder
// is only ever called once, from init.
text_obj: ?*c.TTF_Text = null,
text_generation: u32 = 0,
text_obj_generation: u32 = 0,
placeholder_obj: ?*c.TTF_Text = null,
// W10 follow-up: the pixel wrap width last applied to both TTF_Text
// objects -- -1 (never a real wrap width) forces the first real sync to
// apply one. Tracked separately from text_generation since rect.w can
// change independently of the text content (Clay assigning real geometry
// after this widget was created with a zeroed rect, a window resize if
// the container is fluid-width) -- see syncText.
wrapped_width: i32 = -1,

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

pub fn setText(self: *Self, s: []const u8) bool {
    const n = @min(s.len, max_len);
    if (self.len == n and std.mem.eql(u8, self.buf[0..n], s[0..n])) return false;
    @memcpy(self.buf[0..n], s[0..n]);
    self.len = n;
    self.text_generation +%= 1;
    return true;
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
    // Step back over one UTF-8 codepoint, not just one byte. A trailing
    // `\n` is a single ASCII byte, so this naturally deletes "the last
    // line break" in one backspace the same as any other character --
    // no special-casing needed for the multi-line case.
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
/// TextField.zig uses. Anchored top-left (not vertically centered like a
/// single-line TextField), since multi-line content has no single "center"
/// to speak of.
///
/// W10 follow-up (Quinn's real click-through feedback): overflow past the
/// box's height was originally left to draw past the rect entirely
/// unclipped -- looked broken, not just "no scrollbar." Real scrolling
/// (reusing ScrollClip.zig's mechanism, built for Clay-managed scrollable
/// *containers*, not a leaf widget's own internal text) is still out of
/// scope for v1, but drawing past your own box's edges into whatever's
/// laid out below/beside it never should have been -- this clips the text
/// draw to the widget's own bounds, same "never spill outside your own
/// rect" property every other widget already gets for free from having a
/// single-line/fixed-size draw. Scoped to just this call (SDL's clip rect
/// is a renderer-wide draw state, not a param passed to
/// TTF_DrawRendererText), cleared right after so it can't leak into
/// anything drawn after this widget in the same frame.
// Styling system Stage 2: draw offset is the widget's own real padding
// (`WidgetHost.effectiveTextPadding`) instead of the original hardcoded
// `+ 6`.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer, padding: c.Clay_Padding) void {
    const active = if (self.len > 0) self.text_obj else self.placeholder_obj;
    if (active) |obj| {
        const clip = c.SDL_Rect{
            .x = @intFromFloat(@floor(self.rect.x)),
            .y = @intFromFloat(@floor(self.rect.y)),
            .w = @intFromFloat(@ceil(self.rect.w)),
            .h = @intFromFloat(@ceil(self.rect.h)),
        };
        _ = c.SDL_SetRenderClipRect(renderer, &clip);
        _ = c.TTF_DrawRendererText(obj, self.rect.x + @as(f32, @floatFromInt(padding.left)), self.rect.y + @as(f32, @floatFromInt(padding.top)));
        _ = c.SDL_SetRenderClipRect(renderer, null);
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

/// F3: see TextField.syncText's doc comment -- same generation-counter
/// shape for the text content itself.
///
/// W10 follow-up (Quinn's real click-through feedback): a line that
/// reaches the box's edge needs to wrap to the next line, not just clip
/// or run past it -- SDL_ttf's TTF_SetTextWrapWidth does real pixel-width
/// word-wrap when given a positive width (0, the original v1 choice, only
/// wraps on embedded `\n` bytes). Unlike the text-content sync above, this
/// can't just be set once at creation: a Clay-managed textarea is created
/// with a *zeroed* rect (Clay assigns the real one after its own layout
/// pass runs, via WidgetHost's generic rectPtr accessor, which bypasses
/// this function entirely), so rect.w may still be 0 the first time this
/// runs -- `wrapped_width` tracks what was last applied so this re-applies
/// whenever rect.w actually changes (initial layout, or a later resize),
/// without calling TTF_SetTextWrapWidth every single frame regardless
/// (its own doc comment warns it may rebuild the text's internal
/// representation, not something to churn unconditionally).
/// Styling system Stage 2: `padding` (already resolved via
/// `WidgetHost.effectiveTextPadding` by the caller) replaces the original
/// hardcoded `- 12` -- wrap width shrinks by the real left+right padding.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font, padding: c.Clay_Padding) void {
    const target_wrap: i32 = @max(0, @as(i32, @intFromFloat(self.rect.w)) - @as(i32, padding.left) - @as(i32, padding.right));
    const wrap_changed = target_wrap != self.wrapped_width;

    if (self.text_obj) |obj| {
        if (self.text_obj_generation != self.text_generation) {
            _ = c.TTF_SetTextString(obj, self.text().ptr, self.len);
            self.text_obj_generation = self.text_generation;
        }
        if (wrap_changed) _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
    } else if (c.TTF_CreateText(engine, font, self.text().ptr, self.len)) |obj| {
        _ = c.TTF_SetTextColor(obj, 255, 255, 255, 255);
        _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
        self.text_obj = obj;
        self.text_obj_generation = self.text_generation;
    }

    if (self.placeholder_obj) |obj| {
        if (wrap_changed) _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
    } else if (c.TTF_CreateText(engine, font, self.placeholder().ptr, self.placeholder_len)) |obj| {
        _ = c.TTF_SetTextColor(obj, 120, 120, 130, 255);
        _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
        self.placeholder_obj = obj;
    }

    if (wrap_changed) self.wrapped_width = target_wrap;
}

/// Must be called before this widget is dropped from the registry -- see
/// Button.destroyText's doc comment.
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
