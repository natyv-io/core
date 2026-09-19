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
