//! Pure UTF-8 codepoint-boundary stepping, shared by TextField/TextArea's
//! cursor movement, backspace, and forward-delete -- the one piece of logic
//! genuinely identical across both widgets (unlike the rest of their shape,
//! which is deliberately duplicated -- see TextArea.zig's own doc comment).
//! No widget-specific state; operates purely on a byte slice + an index.

const std = @import("std");

/// Shared by TextField/TextArea (each re-exports this as its own
/// `CursorDirection`) and by WidgetHost's `moveCursorOn` -- one definition
/// so a direction value can be passed straight through without an
/// enum-to-enum cast between two independently-declared identical enums.
pub const CursorDirection = enum { left, right };

fn isContinuationByte(b: u8) bool {
    return (b & 0xC0) == 0x80;
}

/// Length of the longest prefix of `s` that is at most `max` bytes and
/// ends on a codepoint boundary -- the drop-in for `@min(s.len, max)` when
/// truncating text into a fixed buffer. A plain byte cut can split a
/// multi-byte sequence and hand SDL/SDL_ttf invalid UTF-8.
pub fn truncatedLen(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and isContinuationByte(s[n])) : (n -= 1) {}
    return n;
}

/// Byte offset of the start of the codepoint immediately before `pos`.
/// `pos` must be 0..=buf.len. Returns 0 if `pos` is already 0. Same
/// "step back over continuation bytes" loop TextField.backspace originally
/// inlined, generalized to any starting position, not just `len`.
pub fn stepBack(buf: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and isContinuationByte(buf[i])) : (i -= 1) {}
    return i;
}

/// Byte offset immediately after the codepoint starting at or containing
/// `pos`. `pos` must be 0..=len. Returns `len` if `pos` is already at or
/// past the end.
pub fn stepForward(buf: []const u8, len: usize, pos: usize) usize {
    if (pos >= len) return len;
    var i = pos + 1;
    while (i < len and isContinuationByte(buf[i])) : (i += 1) {}
    return i;
}

test "stepBack steps over multi-byte codepoints" {
    // "a\xC3\xA9b" == 'a' (index 0) + U+00E9 'e' (2 bytes, index 1-2) + 'b' (index 3)
    const buf = "a\xC3\xA9b";
    try std.testing.expectEqual(@as(usize, 3), stepBack(buf, 4)); // end -> start of 'b'
    try std.testing.expectEqual(@as(usize, 1), stepBack(buf, 3)); // start of 'b' -> start of the 2-byte 'e'
}

test "stepBack at start returns 0" {
    try std.testing.expectEqual(@as(usize, 0), stepBack("abc", 0));
}

test "stepForward steps over multi-byte codepoints" {
    const buf = "a\xC3\xA9b";
    try std.testing.expectEqual(@as(usize, 3), stepForward(buf, buf.len, 1)); // from start of 'e' -> start of 'b'
    try std.testing.expectEqual(@as(usize, 4), stepForward(buf, buf.len, 3)); // from 'b' -> end
}

test "stepForward at end returns len" {
    try std.testing.expectEqual(@as(usize, 3), stepForward("abc", 3, 3));
}

test "truncatedLen never splits a multi-byte sequence" {
    // "aé€😀" = 1 + 2 + 3 + 4 bytes.
    const s = "a\u{e9}\u{20ac}\u{1f600}";
    try std.testing.expectEqual(@as(usize, 10), truncatedLen(s, 64));
    try std.testing.expectEqual(@as(usize, 10), truncatedLen(s, 10));
    try std.testing.expectEqual(@as(usize, 6), truncatedLen(s, 9));
    try std.testing.expectEqual(@as(usize, 6), truncatedLen(s, 7));
    try std.testing.expectEqual(@as(usize, 3), truncatedLen(s, 5));
    try std.testing.expectEqual(@as(usize, 1), truncatedLen(s, 2));
    try std.testing.expectEqual(@as(usize, 0), truncatedLen(s, 0));
    for (0..s.len + 1) |max| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(s[0..truncatedLen(s, max)]));
    }
}
