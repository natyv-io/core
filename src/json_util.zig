const std = @import("std");

/// Appends `s` to `out` as a properly escaped, double-quoted JSON string.
pub fn writeString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            0...0x1f => try out.print(allocator, "\\u{x:0>4}", .{ch}),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}
