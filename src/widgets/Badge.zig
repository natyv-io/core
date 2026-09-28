//! A small filled pill with centered label text -- used for short semantic
//! status text (a category, a state, a count). Purely decorative, same
//! "pure display" treatment `ProgressBar`/`Label` already get: excluded
//! from hit-testing, hover, and Tab order entirely (see main.zig's
//! non-interactive catch-alls). No dismiss ("x") button in v1 -- a
//! dismissible tag is guest-composed from a Badge plus an adjacent Button,
//! same "guest composes it from primitives" precedent Breadcrumbs/Dialog
//! already established, not a host-level feature of Badge itself.

const std = @import("std");
const text_cursor = @import("text_cursor.zig");
const c = @import("../c.zig").c;

const Self = @This();

const max_label_len = 63;

/// Semantic color tones -- nothing in natyv today lets a guest pick an
/// arbitrary widget color (every existing widget's palette is hardcoded in
/// its own fillColor()); a small fixed enum keeps that precedent rather
/// than making Badge the first widget to accept a raw {r,g,b,a}, which
/// would be the first real piece of the eventual styling system (see
/// project memory) -- premature to introduce piecemeal here.
pub const Tone = enum { primary, success, warning, danger, neutral };

rect: c.SDL_FRect,
tone: Tone = .neutral,
label_buf: [max_label_len + 1]u8 = undefined,
label_len: usize = 0,
// F3-style cached TTF_Text handle -- see Button.zig's fields of the same
// name/purpose for the full explanation.
text_obj: ?*c.TTF_Text = null,
text_generation: u32 = 0,
text_obj_generation: u32 = 0,
sync_count: u32 = 0,

pub fn init(rect: c.SDL_FRect, tone: Tone, initial_label: []const u8) Self {
    var self: Self = .{ .rect = rect, .tone = tone };
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

/// L4.5: the solid-color background fill this widget wants drawn this
/// frame -- unlike `Checkbox`'s conditional fill, a Badge always fills
/// (it's a pill, not a checkmark-on-demand), same "always fills" precedent
/// `Divider.zig` already established.
pub fn fillColor(self: Self) c.SDL_Color {
    return switch (self.tone) {
        .primary => .{ .r = 70, .g = 140, .b = 230, .a = 255 },
        .success => .{ .r = 60, .g = 170, .b = 100, .a = 255 },
        .warning => .{ .r = 210, .g = 160, .b = 50, .a = 255 },
        .danger => .{ .r = 210, .g = 80, .b = 70, .a = 255 },
        .neutral => .{ .r = 90, .g = 94, .b = 106, .a = 255 },
    };
}

/// Label text, centered both horizontally and vertically -- unlike
/// `Checkbox`/`Toggle`'s left-anchored label (which sits *next to* a
/// control), a Badge's text *is* its entire content.
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer) void {
    _ = renderer;
    if (self.text_obj) |obj| {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetTextSize(obj, &w, &h);
        _ = c.TTF_DrawRendererText(obj, self.rect.x + self.rect.w / 2 - @as(f32, @floatFromInt(w)) / 2, self.rect.y + self.rect.h / 2 - @as(f32, @floatFromInt(h)) / 2);
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
