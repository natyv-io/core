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
// F3: cached TTF_Text handle for this button's label, created lazily and
// only re-set (via TTF_SetTextString) when the label actually changed --
// see `syncText`'s doc comment for why this needs a generation counter
// rather than just comparing content directly.
text_obj: ?*c.TTF_Text = null,
text_generation: u32 = 0,
text_obj_generation: u32 = 0,
/// Bumped only when `syncText` actually calls `TTF_CreateText`/
/// `TTF_SetTextString`, never on a no-op sync -- exists purely so tests can
/// assert the dirty-flag skip is real, same role `ClayLayout.recompute_count`
/// plays for L4.
sync_count: u32 = 0,
/// Keyboard interaction model: true when this button has focus (via Tab
/// navigation or a mouse click) -- driven by `WidgetHost.setFocused`
/// through `Widget.setFocusedFlag`, mirrors `TextField.focused`. Space or
/// Enter while a button is focused activates it the same way a mouse click
/// does (see `main.zig`'s `SDL_EVENT_KEY_DOWN` handling).
focused: bool = false,

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
    self.text_generation +%= 1;
}

pub fn label(self: *const Self) []const u8 {
    return self.label_buf[0..self.label_len];
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
///
/// F3: draws the real glyph-rendered `text_obj` (kept in sync by
/// `syncText`, called once per frame on the live registry before this
/// widget's snapshot copy is taken -- see `WidgetHost.syncTextObjects`).
/// Doesn't create it here: `drawDecorations` runs against a per-frame
/// snapshot *copy*, not the live registry, so any state it set here
/// wouldn't survive to the next frame.
///
/// Keyboard interaction model: draws a focus-ring border when `focused` --
/// same treatment (color, inset) as `TextField.drawDecorations`'s existing
/// border, so focus reads consistently across widget kinds regardless of
/// whether it was reached by Tab or by a mouse click.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    if (self.text_obj) |obj| {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetTextSize(obj, &w, &h);
        _ = c.TTF_DrawRendererText(obj, self.rect.x + 10, self.rect.y + self.rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

/// F3: creates this button's `TTF_Text` on first sync, or updates it via
/// `TTF_SetTextString` only when the label actually changed since the last
/// sync (`text_generation` vs. `text_obj_generation` -- bumped by
/// `setLabel`, compared here rather than diffing buffer contents directly,
/// matching the same generation-counter shape `layout_generation` already
/// established for Clay's own dirty-flag caching). Must run against the
/// *live* registry copy (see `WidgetHost.syncTextObjects`), not a snapshot.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
    if (self.text_obj) |obj| {
        if (self.text_obj_generation != self.text_generation) {
            _ = c.TTF_SetTextString(obj, self.label().ptr, self.label_len);
            self.text_obj_generation = self.text_generation;
            self.sync_count += 1;
        }
    } else if (c.TTF_CreateText(engine, font, self.label().ptr, self.label_len)) |obj| {
        _ = c.TTF_SetTextColor(obj, 255, 255, 255, 255);
        self.text_obj = obj;
        self.text_obj_generation = self.text_generation;
        self.sync_count += 1;
    }
}

/// Must be called before this widget is dropped from the registry --
/// SDL_ttf requires every `TTF_Text` be destroyed before its owning
/// `TTF_TextEngine` is (see `WidgetHost.destroyWidgetHostFn` and
/// `main.zig`'s shutdown-ordering `defer`).
pub fn destroyText(self: *Self) void {
    if (self.text_obj) |obj| {
        c.TTF_DestroyText(obj);
        self.text_obj = null;
    }
}
