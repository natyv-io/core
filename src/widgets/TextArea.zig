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
const text_cursor = @import("text_cursor.zig");

const Self = @This();

pub const max_len = 1023;
const max_placeholder_len = 63;

pub const CursorDirection = text_cursor.CursorDirection;

rect: c.SDL_FRect,
placeholder_buf: [max_placeholder_len + 1]u8 = undefined,
placeholder_len: usize = 0,
buf: [max_len + 1]u8 = undefined,
len: usize = 0,
focused: bool = false,
/// See TextField.zig's identical field for the full doc comment -- these
/// two widgets deliberately mirror each other's shape throughout.
cursor: usize = 0,
selection_anchor: ?usize = null,
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

// Correction, 2026-09-11, same day: this constructor briefly called
// setText here instead of setPlaceholder, on the mistaken assumption that
// CreateTextArea's 2nd param was meant as general initial content. Real,
// deliberate, already-established design (confirmed by re-reading
// shared/src/ntx/Codegen.zig's own TextArea emission, dated 2026-09-02,
// which documents the identical wrong assumption being made and corrected
// once already): this param genuinely is placeholder-only, by design --
// `.ntx`'s own codegen already routes any real/dynamic content
// (`text={expr}`) through a separate `.SetText(...)` call emitted right
// after creation, never through this constructor arg at all. Plain
// literal child text with no `text=` attribute (e.g. a compose body
// field's "Body" hint) is the one case that *does* go through this param
// directly -- and it's real hint text, not seed content: rendering it via
// setText instead (today's brief mistake) is exactly what made it show up
// in the same bright, non-dimmed style as real user-typed content instead
// of the dimmed placeholder style TextField's To/Subject fields correctly
// use, which is what Quinn actually flagged. Reverted back to match.
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

/// See TextField.setText's doc comment -- same "reset to end, clear
/// selection" reasoning for a programmatic replace.
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

/// See TextField.insertAt's doc comment -- same insert-at-cursor path,
/// used by both typed characters and paste (and, here, the Enter key's
/// literal-newline insertion). Supersedes the old append-only
/// `appendText`. Also see that same doc comment for a real, live-found bug
/// fix: a plain click leaves a collapsed (cursor == anchor) but still
/// non-null `selection_anchor`, which `deleteSelection`'s own early return
/// never clears when there's nothing to actually delete -- explicitly
/// nulling it here (not just relying on `deleteSelection`) stops that
/// stale anchor from turning into a phantom selection the *next* edit
/// would wrongly delete.
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

/// Backspace: deletes the selection if active, else the one UTF-8
/// codepoint immediately before the cursor. A trailing `\n` is a single
/// ASCII byte, so this naturally deletes "the last line break" in one
/// backspace the same as any other character -- no special-casing needed
/// for the multi-line case. Same stale-anchor fix as `insertAt` -- see its
/// doc comment.
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

/// Forward-delete (the Delete/Fn+Delete key) -- the mirror image of
/// `backspace`. Same stale-anchor fix as `insertAt`/`backspace` -- see
/// `insertAt`'s doc comment.
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

/// See TextField.moveCursor's doc comment -- identical semantics.
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
pub fn drawDecorations(self: Self, renderer: ?*c.SDL_Renderer, padding: c.Clay_Padding, font: *c.TTF_Font) void {
    const active = if (self.len > 0) self.text_obj else self.placeholder_obj;
    if (active) |obj| {
        const clip = c.SDL_Rect{
            .x = @intFromFloat(@floor(self.rect.x)),
            .y = @intFromFloat(@floor(self.rect.y)),
            .w = @intFromFloat(@ceil(self.rect.w)),
            .h = @intFromFloat(@ceil(self.rect.h)),
        };
        _ = c.SDL_SetRenderClipRect(renderer, &clip);
        const text_x = self.rect.x + @as(f32, @floatFromInt(padding.left));
        const text_y = self.rect.y + @as(f32, @floatFromInt(padding.top));
        _ = c.TTF_DrawRendererText(obj, text_x, text_y);

        // Selection highlight / caret -- see TextField.drawDecorations's
        // identical block for the full reasoning (this widget's own
        // syncText actively destroys text_obj whenever len == 0, so the
        // empty-focused-caret case here is equally reliant on the
        // placeholder's own line-height rather than any TTF measurement).
        // Kept inside the same clip-rect-active window as the text draw
        // above, so a caret/highlight scrolled past the visible box gets
        // clipped exactly like the text itself already is.
        if (self.focused) {
            if (self.len > 0 and self.text_obj != null) {
                const text_obj = self.text_obj.?;
                if (self.hasSelection()) {
                    const range = self.selectionRange().?;
                    var count: c_int = 0;
                    if (c.TTF_GetTextSubStringsForRange(text_obj, @intCast(range.start), @intCast(range.end - range.start), &count)) |substrings| {
                        // See TextField.drawDecorations's identical block
                        // for why an explicit ptrCast is needed here.
                        defer c.SDL_free(@ptrCast(substrings));
                        var i: usize = 0;
                        while (substrings[i] != null) : (i += 1) {
                            // See TextField.drawDecorations's identical
                            // block for why [0] is required here.
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
                    // Real bug, found live and confirmed with a second real
                    // screenshot (Quinn: a trailing space still didn't
                    // advance the caret even after the previous-character
                    // fix -- status label proved the space really was in
                    // the buffer, so this was never a data bug). See
                    // TextField.zig's identical block for the full root
                    // cause: TTF_SubString.rect is a real *ink* bounding
                    // box, not a cursor-advance width -- a space has no ink,
                    // so rect.w for a space's own substring is ~0
                    // regardless of which offset it's queried at. Fixed the
                    // same way: use the previous codepoint's rect only for
                    // its LEFT edge and its LINE (`sub.rect.y`/`sub.rect.h`
                    // -- still accurate, only WIDTH was ever wrong, and a
                    // multi-line cursor position isn't at the top line in
                    // general), then add that exact codepoint's real
                    // advance width measured directly via TTF_GetStringSize
                    // against just those bytes. `cursor == 0` has no
                    // previous character to correct for. One known, narrow
                    // gap this doesn't cover: a cursor sitting exactly at a
                    // word-wrap break reached via navigation (not typing)
                    // will show at the *previous* line's own end rather
                    // than the new line's start -- out of scope for the bug
                    // actually reported here.
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
                            .y = text_y + @as(f32, @floatFromInt(sub.rect.y)),
                            .w = 2,
                            .h = @floatFromInt(sub.rect.h),
                        };
                        _ = c.SDL_RenderFillRect(renderer, &caret);
                    }
                }
            } else if (self.len == 0) {
                var w: c_int = 0;
                var ph: c_int = 0;
                if (self.placeholder_obj) |pobj| _ = c.TTF_GetTextSize(pobj, &w, &ph);
                _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
                const caret = c.SDL_FRect{ .x = text_x, .y = text_y, .w = 2, .h = @floatFromInt(ph) };
                _ = c.SDL_RenderFillRect(renderer, &caret);
            }
        }
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

    // Real bug, found 2026-09-11 -- see Label.syncText's own doc comment for
    // the full evidence trail (temporary diagnostic logging proved the
    // widget's own buffer was correctly empty at creation time, so the
    // corruption happens inside/after SDL_ttf's own zero-length handling,
    // not before it). Same fix here: never hand SDL_ttf a zero-length
    // create/update. Doubly relevant for this widget specifically --
    // placeholder_len is effectively *always* 0 today, now that
    // TextArea.init's own real-content fix (same day) means nothing calls
    // setPlaceholder anymore; without this guard, every real TextArea
    // would hit the exact zero-length TTF_CreateText bug for its
    // placeholder_obj on every single sync, even though that object is
    // only ever actually drawn when self.len == 0 in the first place.
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
        _ = c.TTF_SetTextColor(obj, 255, 255, 255, 255);
        _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
        self.text_obj = obj;
        self.text_obj_generation = self.text_generation;
    }

    if (self.placeholder_obj) |obj| {
        if (wrap_changed) _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
    } else if (self.placeholder_len > 0) {
        if (c.TTF_CreateText(engine, font, self.placeholder().ptr, self.placeholder_len)) |obj| {
            _ = c.TTF_SetTextColor(obj, 120, 120, 130, 255);
            _ = c.TTF_SetTextWrapWidth(obj, target_wrap);
            self.placeholder_obj = obj;
        }
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

fn testArea() Self {
    return Self.init(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, "placeholder");
}

test "insertAt after a plain click does not drop the first typed character" {
    // See TextField.zig's identical test for the real bug this reproduces.
    var f = testArea();
    f.cursor = 0;
    f.selection_anchor = 0;
    f.insertAt("Q");
    f.insertAt("u");
    try std.testing.expectEqualStrings("Qu", f.text());
}

test "insertAt replaces an active selection" {
    var f = testArea();
    _ = f.setText("Hello");
    f.selection_anchor = 1;
    f.cursor = 4;
    f.insertAt("X");
    try std.testing.expectEqualStrings("HXo", f.text());
    try std.testing.expectEqual(@as(usize, 2), f.cursor);
    try std.testing.expect(f.selection_anchor == null);
}

test "backspace at a mid-text cursor deletes the preceding codepoint, not the end" {
    var f = testArea();
    _ = f.setText("Hello");
    f.cursor = 2;
    f.selection_anchor = 2;
    f.backspace();
    try std.testing.expectEqualStrings("Hllo", f.text());
    try std.testing.expectEqual(@as(usize, 1), f.cursor);
    try std.testing.expect(f.selection_anchor == null);
}

test "deleteForward at a mid-text cursor deletes the following codepoint" {
    var f = testArea();
    _ = f.setText("Hello");
    f.cursor = 2;
    f.selection_anchor = 2;
    f.deleteForward();
    try std.testing.expectEqualStrings("Helo", f.text());
    try std.testing.expectEqual(@as(usize, 2), f.cursor);
    try std.testing.expect(f.selection_anchor == null);
}

test "moveCursor without extend collapses to the selection's near edge" {
    var f = testArea();
    _ = f.setText("Hello");
    f.selection_anchor = 1;
    f.cursor = 4;
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
    var f = testArea();
    _ = f.setText("Hello");
    f.cursor = 2;
    f.selection_anchor = 2;
    _ = f.moveCursor(.right, true);
    try std.testing.expectEqual(@as(usize, 3), f.cursor);
    try std.testing.expectEqual(@as(usize, 2), f.selection_anchor.?);
    try std.testing.expect(f.hasSelection());
}

test "backspace deletes a trailing newline as a single codepoint" {
    var f = testArea();
    _ = f.setText("line one\nline two");
    f.cursor = 9; // right after the \n
    f.selection_anchor = 9;
    f.backspace();
    try std.testing.expectEqualStrings("line oneline two", f.text());
}
