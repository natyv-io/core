//! A toggleable box with an optional label, focusable and keyboard-
//! activatable (Space/Enter) the same way `Button` is clickable -- see
//! `main.zig`'s widened `SDLK_SPACE`/`SDLK_RETURN` activation arm. The box
//! occupies the left `rect.h`-square portion of `rect`; the label (if any)
//! is drawn to its right. The whole `rect` (box + label) is the click/focus
//! target, same convention `Button` already uses for its full rect.

const c = @import("../c.zig").c;

const Self = @This();

const max_label_len = 127;
const label_gap = 8;

rect: c.SDL_FRect,
checked: bool = false,
label_buf: [max_label_len + 1]u8 = undefined,
label_len: usize = 0,
// F3-style cached TTF_Text handle for the label -- see Button.zig's fields
// of the same name/purpose for the full explanation.
text_obj: ?*c.TTF_Text = null,
text_generation: u32 = 0,
text_obj_generation: u32 = 0,
sync_count: u32 = 0,
/// Keyboard interaction model: see Button.focused's doc comment.
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

/// The square the box itself occupies, within `rect` -- distinct from
/// `rect` (which also spans the label) since only the box should ever be
/// filled/outlined, not the label area.
pub fn boxRect(self: Self) c.SDL_FRect {
    return .{ .x = self.rect.x, .y = self.rect.y, .w = self.rect.h, .h = self.rect.h };
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

pub fn toggle(self: *Self) void {
    self.checked = !self.checked;
}

/// L4.5-style batched fill -- only meaningful when checked (an unchecked
/// box has nothing to fill, just the outline `drawDecorations` always
/// draws). `Widget.fillRect` returns `null` for an unchecked checkbox
/// rather than calling this with a checked=false understanding baked in,
/// so this only needs to answer "what color when checked."
pub fn fillColor(self: Self) c.SDL_Color {
    _ = self;
    return .{ .r = 70, .g = 140, .b = 230, .a = 255 };
}

/// The box outline (always) and checkmark (when checked) plus the label
/// text and focus ring -- see `Button.drawDecorations`'s doc comment for
/// why creation/sync can't happen here (this runs against a per-frame
/// snapshot copy, not the live registry).
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    const box = self.boxRect();
    _ = c.SDL_SetRenderDrawColor(renderer, 140, 140, 150, 255);
    _ = c.SDL_RenderRect(renderer, &box);

    if (self.checked) {
        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
        _ = c.SDL_RenderLine(renderer, box.x + box.w * 0.2, box.y + box.h * 0.55, box.x + box.w * 0.45, box.y + box.h * 0.78);
        _ = c.SDL_RenderLine(renderer, box.x + box.w * 0.45, box.y + box.h * 0.78, box.x + box.w * 0.82, box.y + box.h * 0.22);
    }

    if (self.text_obj) |obj| {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetTextSize(obj, &w, &h);
        _ = c.TTF_DrawRendererText(obj, self.rect.x + self.rect.h + label_gap, self.rect.y + self.rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
    }

    if (self.focused) {
        _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 255);
        const border = c.SDL_FRect{ .x = self.rect.x - 1, .y = self.rect.y - 1, .w = self.rect.w + 2, .h = self.rect.h + 2 };
        _ = c.SDL_RenderRect(renderer, &border);
    }
}

/// See `Button.syncText`'s doc comment -- identical shape.
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

/// See `Button.destroyText`'s doc comment.
pub fn destroyText(self: *Self) void {
    if (self.text_obj) |obj| {
        c.TTF_DestroyText(obj);
        self.text_obj = null;
    }
}
