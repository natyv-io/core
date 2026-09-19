//! A single-line text input box. Native-drawn via SDL, focused by clicking
//! inside it; while focused, receives SDL_EVENT_TEXT_INPUT for typed
//! characters and backspace via SDL_EVENT_KEY_DOWN. Placeholder is
//! guest-supplied at creation; content is host-owned (typed by the user) but
//! readable/settable by the guest via natyv_get_text/natyv_set_text.

const std = @import("std");
const c = @import("../c.zig").c;
const text_cursor = @import("text_cursor.zig");

const Self = @This();

pub const max_len = 127;
const max_placeholder_len = 63;

pub const CursorDirection = text_cursor.CursorDirection;

rect: c.SDL_FRect,
placeholder_buf: [max_placeholder_len + 1]u8 = undefined,
placeholder_len: usize = 0,
buf: [max_len + 1]u8 = undefined,
len: usize = 0,
focused: bool = false,
/// Byte offset into `buf`, always 0..=len and always on a UTF-8 codepoint
/// boundary. Defaults to end-of-text so any caller that never touches
/// cursor movement (typing, backspace) behaves exactly as it did before
/// this field existed.
cursor: usize = 0,
/// The other edge of an active selection -- null means no selection (just
/// a caret at `cursor`). Equal to `cursor` also means no selection (a
/// collapsed range); see `hasSelection`.
selection_anchor: ?usize = null,
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

/// A programmatic replace (guest-driven natyv_set_text) always lands the
/// cursor at the new end and clears any selection -- the old cursor's byte
/// offset has no reliable meaning against entirely different content, so
/// clamping it in place risks landing mid-codepoint; resetting to end
/// mirrors this widget's original (pre-cursor) append-only behavior.
pub fn setText(self: *Self, s: []const u8) bool {
    const n = @min(s.len, max_len);
    if (self.len == n and std.mem.eql(u8, self.buf[0..n], s[0..n])) return false;
    @memcpy(self.buf[0..n], s[0..n]);
    self.len = n;
    self.cursor = n;
    self.selection_anchor = null;
    self.text_generation +%= 1;
    return true;
}

pub fn clear(self: *Self) void {
    self.len = 0;
    self.cursor = 0;
    self.selection_anchor = null;
    self.text_generation +%= 1;
}

pub fn hasSelection(self: Self) bool {
    return self.selection_anchor != null and self.selection_anchor.? != self.cursor;
}

pub fn selectionRange(self: Self) ?struct { start: usize, end: usize } {
    const anchor = self.selection_anchor orelse return null;
    if (anchor == self.cursor) return null;
    return if (anchor < self.cursor) .{ .start = anchor, .end = self.cursor } else .{ .start = self.cursor, .end = anchor };
}

pub fn deleteSelection(self: *Self) void {
    const range = self.selectionRange() orelse return;
    const tail_len = self.len - range.end;
    std.mem.copyForwards(u8, self.buf[range.start..][0..tail_len], self.buf[range.end..][0..tail_len]);
    self.len = range.start + tail_len;
    self.cursor = range.start;
    self.selection_anchor = null;
    self.text_generation +%= 1;
}

/// The general insert-at-cursor path -- typed characters and paste both go
/// through this (deleting the selection first, if any). Supersedes the old
/// append-only `appendText`: when there's no selection and `cursor == len`
/// (the default, untouched-by-the-user state), behavior is identical to
/// the old append-to-end.
///
/// Real bug, found live (Quinn: typed "Quinn", "Q" rendered then got
/// replaced by "u" on the very next keystroke): a plain click sets
/// `cursor == selection_anchor` (a collapsed selection, correctly reported
/// as "no selection" by `hasSelection`/`selectionRange`) -- but
/// `deleteSelection`'s own `orelse return` only ever clears
/// `selection_anchor` when there was a real, non-empty range to delete.
/// The stale, still-non-null anchor survives the first insert untouched
/// (cursor moves away from it, anchor doesn't), so it silently becomes a
/// *real* selection covering exactly the just-typed character -- which the
/// *second* keystroke's own `deleteSelection` call then faithfully deletes
/// before inserting, deleting first character in the process. Fixed by
/// always clearing the anchor here, not just when `deleteSelection` found
/// something to actually delete.
pub fn insertAt(self: *Self, s: []const u8) void {
    self.deleteSelection();
    self.selection_anchor = null;
    const room = max_len - self.len;
    const n = @min(room, s.len);
    if (n == 0) return;
    const tail_len = self.len - self.cursor;
    std.mem.copyBackwards(u8, self.buf[self.cursor + n ..][0..tail_len], self.buf[self.cursor..][0..tail_len]);
    @memcpy(self.buf[self.cursor..][0..n], s[0..n]);
    self.len += n;
    self.cursor += n;
    self.text_generation +%= 1;
}

/// Backspace: deletes the selection if one is active, else the one UTF-8
/// codepoint immediately before the cursor (not necessarily at the end of
/// the buffer anymore). Same stale-anchor bug as `insertAt` applies here
/// too -- see its doc comment -- so the no-selection branch also clears
/// `selection_anchor` explicitly rather than leaving it wherever the last
/// click/selection op put it.
pub fn backspace(self: *Self) void {
    if (self.hasSelection()) {
        self.deleteSelection();
        return;
    }
    self.selection_anchor = null;
    if (self.cursor == 0) return;
    const start = text_cursor.stepBack(self.buf[0..self.len], self.cursor);
    const tail_len = self.len - self.cursor;
    std.mem.copyForwards(u8, self.buf[start..][0..tail_len], self.buf[self.cursor..][0..tail_len]);
    self.len = start + tail_len;
    self.cursor = start;
    self.text_generation +%= 1;
}

/// Forward-delete (the Delete/Fn+Delete key): the mirror image of
/// `backspace` -- deletes the selection if active, else the one codepoint
/// immediately after the cursor. Same stale-anchor fix as `insertAt`/
/// `backspace` -- see `insertAt`'s doc comment.
pub fn deleteForward(self: *Self) void {
    if (self.hasSelection()) {
        self.deleteSelection();
        return;
    }
    self.selection_anchor = null;
    if (self.cursor >= self.len) return;
    const end = text_cursor.stepForward(self.buf[0..self.len], self.len, self.cursor);
    const tail_len = self.len - end;
    std.mem.copyForwards(u8, self.buf[self.cursor..][0..tail_len], self.buf[end..][0..tail_len]);
    self.len = self.cursor + tail_len;
    self.text_generation +%= 1;
}

/// Arrow-key cursor movement. `extend` (Shift held) grows/shrinks the
/// selection instead of collapsing it. Without `extend`, moving away from
/// an active selection jumps to that selection's edge in the given
/// direction and collapses it -- standard text-field convention, not an
/// extra step from wherever the bare cursor happened to be. Returns
/// whether anything actually changed (cursor position or selection
/// state), so the caller knows whether a redraw is needed.
pub fn moveCursor(self: *Self, direction: CursorDirection, extend: bool) bool {
    const old_cursor = self.cursor;
    const old_anchor = self.selection_anchor;
    if (extend) {
        if (self.selection_anchor == null) self.selection_anchor = self.cursor;
        self.cursor = switch (direction) {
            .left => text_cursor.stepBack(self.buf[0..self.len], self.cursor),
            .right => text_cursor.stepForward(self.buf[0..self.len], self.len, self.cursor),
        };
    } else {
        if (self.selectionRange()) |range| {
            self.cursor = switch (direction) {
                .left => range.start,
                .right => range.end,
            };
        } else {
            self.cursor = switch (direction) {
                .left => text_cursor.stepBack(self.buf[0..self.len], self.cursor),
                .right => text_cursor.stepForward(self.buf[0..self.len], self.len, self.cursor),
            };
        }
        self.selection_anchor = null;
    }
    return self.cursor != old_cursor or self.selection_anchor != old_anchor;
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
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer, padding: c.Clay_Padding, font: *c.TTF_Font) void {
    const active = if (self.len > 0) self.text_obj else self.placeholder_obj;
    if (active) |obj| {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.TTF_GetTextSize(obj, &w, &h);
        const text_x = self.rect.x + @as(f32, @floatFromInt(padding.left));
        const text_y = self.rect.y + self.rect.h / 2 - @as(f32, @floatFromInt(h)) / 2;
        _ = c.TTF_DrawRendererText(obj, text_x, text_y);

        // Selection highlight / caret: only meaningful against real entered
        // text (self.text_obj), never the placeholder. An empty, focused
        // field always has cursor == 0 (zero-length text has nowhere else
        // for it to be), so that caret needs no TTF measurement at all --
        // just the plain text origin and the placeholder's own line-height
        // (a reasonable proxy, and the only real TTF_Text available here).
        if (self.focused) {
            if (self.len > 0 and self.text_obj != null) {
                const text_obj = self.text_obj.?;
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    var count: c_int = 0;
                    if (c.TTF_GetTextSubStringsForRange(text_obj, @intCast(range.start), @intCast(range.end - range.start), &count)) |substrings| {
                        // TTF_SubString** doesn't implicitly coerce to
                        // ?*anyopaque the way a single [*c]T does.
                        defer c.SDL_free(@ptrCast(substrings));
                        var i: usize = 0;
                        while (substrings[i] != null) : (i += 1) {
                            // TTF_SubString** through translate-c: each
                            // element is a [*c]TTF_SubString many-pointer,
                            // not a single-item pointer -- needs [0], plain
                            // `.rect` field access doesn't compile on it.
                            const sub = substrings[i].?;
                            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);
                            _ = c.SDL_SetRenderDrawColor(renderer, 235, 120, 50, 90);
                            const hl = c.SDL_FRect{
                                .x = text_x + @as(f32, @floatFromInt(sub[0].rect.x)),
                                .y = text_y + @as(f32, @floatFromInt(sub[0].rect.y)),
                                .w = @floatFromInt(sub[0].rect.w),
                                .h = @floatFromInt(sub[0].rect.h),
                            };
                            _ = c.SDL_RenderFillRect(renderer, &hl);
                            _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_NONE);
                        }
                    }
                } else {
                    // Real bug, found live and confirmed with a second
                    // real screenshot (Quinn: a trailing space still didn't
                    // advance the caret even after querying the *previous*
                    // character instead of the end-of-text boundary --
                    // status label proved the space really was in the
                    // buffer the whole time, so this was never a data bug).
                    // Root cause, confirmed by the numbers lining up
                    // exactly against that screenshot: `TTF_SubString.rect`
                    // is a real *ink* bounding box, not a cursor-advance
                    // width -- a space has no ink, so `rect.w` for a space
                    // character's own substring is ~0 regardless of which
                    // offset it's queried at, boundary or not. The correct
                    // advance distance can only come from the font itself,
                    // not from any TTF_Text substring rect. Fixed by using
                    // the previous codepoint's own rect only for its LEFT
                    // edge (still accurate -- only WIDTH was ever wrong),
                    // then adding that exact codepoint's real advance width
                    // measured directly via TTF_GetStringSize against just
                    // those bytes. `cursor == 0` has no previous character
                    // to correct for -- querying offset 0 directly needs no
                    // width correction at all, since there's nothing before
                    // it to have measured wrong.
                    var sub: c.TTF_SubString = undefined;
                    const query_offset: usize = if (self.cursor > 0) text_cursor.stepBack(self.buf[0..self.len], self.cursor) else 0;
                    if (c.TTF_GetTextSubString(text_obj, @intCast(query_offset), &sub)) {
                        var caret_x = sub.rect.x;
                        if (self.cursor > 0) {
                            const char_end = text_cursor.stepForward(self.buf[0..self.len], self.len, query_offset);
                            const char_bytes = self.buf[query_offset..char_end];
                            var char_w: c_int = 0;
                            var char_h: c_int = 0;
                            _ = c.TTF_GetStringSize(font, char_bytes.ptr, char_bytes.len, &char_w, &char_h);
                            caret_x += char_w;
                        }
                        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
                        const caret = c.SDL_FRect{
                            .x = text_x + @as(f32, @floatFromInt(caret_x)),
                            .y = text_y,
                            .w = 2,
                            .h = @floatFromInt(h),
                        };
                        _ = c.SDL_RenderFillRect(renderer, &caret);
                    }
                }
            } else if (self.len == 0) {
                _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
                const caret = c.SDL_FRect{ .x = text_x, .y = text_y, .w = 2, .h = @floatFromInt(h) };
                _ = c.SDL_RenderFillRect(renderer, &caret);
            }
        }
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
///
/// Real bug, found via a real crash (not caught by any unit test): this
/// never had the same zero-length guard `TextArea.syncText`/`Label`'s own
/// fix already carry (see `project_natyv_garbled_text_fix` memory --
/// `TTF_CreateText` mishandles a zero-length string). It never mattered
/// before, because `drawDecorations` only ever drew `placeholder_obj` while
/// `len == 0`, never touching a zero-length `text_obj` at all -- but the
/// new cursor/selection code queries `text_obj` directly whenever it's
/// non-null, regardless of `len`, which is exactly what a fresh, empty,
/// clicked TextField hits on its very first sync. Same fix as TextArea's:
/// destroy and null `text_obj` while empty instead of ever creating one
/// from a zero-length string.
pub fn syncText(self: *Self, engine: *c.TTF_TextEngine, font: *c.TTF_Font) void {
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

fn testField() Self {
    return Self.init(.{ .x = 0, .y = 0, .w = 100, .h = 24 }, "placeholder");
}

test "insertAt after a plain click does not drop the first typed character" {
    // Regression test for the real bug Quinn hit live: typing "Quinn" into
    // a freshly-clicked, empty field rendered "Q", then lost it entirely
    // the moment "u" was typed. A plain click sets cursor == anchor (a
    // collapsed selection) -- without insertAt explicitly clearing the
    // anchor, it survives the first insert untouched and becomes a real,
    // phantom selection the second insert's own deleteSelection call then
    // faithfully deletes.
    var f = testField();
    f.cursor = 0;
    f.selection_anchor = 0; // what a real click on an empty field sets
    f.insertAt("Q");
    f.insertAt("u");
    try std.testing.expectEqualStrings("Qu", f.text());
}

test "insertAt replaces an active selection" {
    var f = testField();
    _ = f.setText("Hello");
    f.selection_anchor = 1;
    f.cursor = 4; // selects "ell"
    f.insertAt("X");
    try std.testing.expectEqualStrings("HXo", f.text());
    try std.testing.expectEqual(@as(usize, 2), f.cursor);
    try std.testing.expect(f.selection_anchor == null);
}

test "backspace at a mid-text cursor deletes the preceding codepoint, not the end" {
    var f = testField();
    _ = f.setText("Hello");
    f.cursor = 2;
    f.selection_anchor = 2; // collapsed, as a real click would leave it
    f.backspace();
    try std.testing.expectEqualStrings("Hllo", f.text());
    try std.testing.expectEqual(@as(usize, 1), f.cursor);
    try std.testing.expect(f.selection_anchor == null);
}

test "deleteForward at a mid-text cursor deletes the following codepoint" {
    var f = testField();
    _ = f.setText("Hello");
    f.cursor = 2;
    f.selection_anchor = 2;
    f.deleteForward();
    try std.testing.expectEqualStrings("Helo", f.text());
    try std.testing.expectEqual(@as(usize, 2), f.cursor);
    try std.testing.expect(f.selection_anchor == null);
}

test "moveCursor without extend collapses to the selection's near edge" {
    var f = testField();
    _ = f.setText("Hello");
    f.selection_anchor = 1;
    f.cursor = 4; // selects "ell"
    _ = f.moveCursor(.left, false);
    try std.testing.expectEqual(@as(usize, 1), f.cursor);
    try std.testing.expect(f.selection_anchor == null);

    f.selection_anchor = 1;
    f.cursor = 4;
    _ = f.moveCursor(.right, false);
    try std.testing.expectEqual(@as(usize, 4), f.cursor);
    try std.testing.expect(f.selection_anchor == null);
}

test "moveCursor with extend grows a selection from a collapsed cursor" {
    var f = testField();
    _ = f.setText("Hello");
    f.cursor = 2;
    f.selection_anchor = 2;
    _ = f.moveCursor(.right, true);
    try std.testing.expectEqual(@as(usize, 3), f.cursor);
    try std.testing.expectEqual(@as(usize, 2), f.selection_anchor.?);
    try std.testing.expect(f.hasSelection());
}
