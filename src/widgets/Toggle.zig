//! A pill-track/circular-thumb toggle -- functionally identical to
//! `Checkbox` (a single `checked: bool`, click/Space/Enter to flip, optional
//! label), differing only in how it draws. See `Checkbox.zig`'s doc comment
//! for the shared focus/activation model this mirrors exactly. The whole
//! `rect` (track + label) is the click/focus target, same convention
//! `Checkbox` already uses for its own box + label.
//!
//! v1 snaps the thumb instantly to its final position on toggle, rather than
//! animating -- matches this project's "ship the static mechanism first"
//! bias (see e.g. W1-W3); an animated slide can follow later if it looks
//! wrong in practice.

const std = @import("std");
const text_cursor = @import("text_cursor.zig");
const c = @import("../c.zig").c;

const Self = @This();

const max_label_len = 127;
const label_gap = 8;
const thumb_inset = 2;

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
    _ = self.setLabel(initial_label);
    return self;
}

pub fn setLabel(self: *Self, s: []const u8) bool {
    const n = text_cursor.truncatedLen(s, max_label_len);
    if (self.label_len == n and std.mem.eql(u8, self.label_buf[0..n], s[0..n])) return false;
    @memcpy(self.label_buf[0..n], s[0..n]);
    self.label_buf[n] = 0;
    self.label_len = n;
    self.text_generation +%= 1;
    return true;
}

pub fn label(self: *const Self) []const u8 {
    return self.label_buf[0..self.label_len];
}

/// The pill the track itself occupies, within `rect` -- distinct from
/// `rect` (which also spans the label) since only the track/thumb should
/// ever be drawn, not the label area. Sized wider than tall (unlike
/// `Checkbox.boxRect`'s square), vertically centered in `rect.h`.
pub fn trackRect(self: Self) c.SDL_FRect {
    const h = self.rect.h * 0.6;
    const w = self.rect.h * 1.8;
    return .{ .x = self.rect.x, .y = self.rect.y + (self.rect.h - h) / 2, .w = w, .h = h };
}

/// The thumb square, inset within the track and pinned to whichever end
/// `checked` currently selects.
pub fn thumbRect(self: Self) c.SDL_FRect {
    const track = self.trackRect();
    const side = track.h - thumb_inset * 2;
    const x = if (self.checked) track.x + track.w - side - thumb_inset else track.x + thumb_inset;
    return .{ .x = x, .y = track.y + thumb_inset, .w = side, .h = side };
}

pub fn containsPoint(self: Self, x: f32, y: f32) bool {
    return x >= self.rect.x and x < self.rect.x + self.rect.w and
        y >= self.rect.y and y < self.rect.y + self.rect.h;
}

pub fn toggle(self: *Self) void {
    self.checked = !self.checked;
}

/// The track's own fill color -- distinct on/off tones, same "semantic
/// color per state" role `Checkbox.fillColor` plays for its checkmark.
fn trackColor(self: Self) c.SDL_Color {
    return if (self.checked)
        .{ .r = 70, .g = 140, .b = 230, .a = 255 }
    else
        .{ .r = 90, .g = 94, .b = 106, .a = 255 };
}

/// Track (always) + thumb (always) + label text + focus ring. Opts out of
/// `Widget.fillRect`'s single-color batched fill (like `ProgressBar`/
/// `Slider`) since a toggle is a real two-color custom draw every frame,
/// not a single conditional fill the way `Checkbox`'s checkmark is.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    const track = self.trackRect();
    const tc = self.trackColor();
    _ = c.SDL_SetRenderDrawColor(renderer, tc.r, tc.g, tc.b, tc.a);
    _ = c.SDL_RenderFillRect(renderer, &track);

    const thumb = self.thumbRect();
    _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
    _ = c.SDL_RenderFillRect(renderer, &thumb);

    if (self.text_obj) |obj| {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetTextSize(obj, &w, &h);
        _ = c.TTF_DrawRendererText(obj, self.rect.x + track.w + label_gap, self.rect.y + self.rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
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
