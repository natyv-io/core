//! Private duplicate of `src/host_fn_util.zig`, parameterized against this
//! directory's own `BindingsC.zig` instead of the shared `src/c.zig` --
//! see `BindingsC.zig`'s own doc comment for why `Bindings`' generated
//! code can't relatively import the real `host_fn_util.zig` either (it's
//! part of the real natyv-core `root` module too, via
//! `WidgetHostFunctions.zig`/`Sqlite.zig`). Kept in sync by hand if the
//! guest wire format ever changes -- a real, accepted duplication cost,
//! but a small one: this logic is stable (governed by the Extism host-
//! function ABI itself, not natyv's own churn) and only 3 short functions.
const std = @import("std");
const c = @import("BindingsC.zig").c;

pub fn readGuestBytes(allocator: std.mem.Allocator, plugin: ?*c.ExtismCurrentPlugin, val: *allowzero const c.ExtismVal) ![]u8 {
    const handle: u64 = @intCast(val.v.i64);
    const len = c.extism_current_plugin_memory_length(plugin, handle);
    const base = c.extism_current_plugin_memory(plugin);
    return allocator.dupe(u8, base[handle .. handle + len]);
}

pub fn writeGuestBytes(plugin: ?*c.ExtismCurrentPlugin, out_val: *allowzero c.ExtismVal, data: []const u8) void {
    const handle = c.extism_current_plugin_memory_alloc(plugin, data.len);
    const base = c.extism_current_plugin_memory(plugin);
    @memcpy(base[handle .. handle + data.len], data);
    out_val.* = .{ .t = c.ExtismValType_I64, .v = .{ .i64 = @intCast(handle) } };
}

pub fn writeErrorJson(plugin: ?*c.ExtismCurrentPlugin, out_val: *allowzero c.ExtismVal, comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "unknown error";
    var out_buf: [320]u8 = undefined;
    const json = std.fmt.bufPrint(&out_buf, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"unknown\"}";
    writeGuestBytes(plugin, out_val, json);
}

// Real drift-protection test added during the post-Stage-2.10
// maintainability pass: this file's own doc comment already says it's
// "kept in sync by hand" with `src/host_fn_util.zig`, but nothing
// actually verified that until now -- a real risk (if a small one,
// given how stable this logic is) that a future bug fix lands in one
// file and is forgotten in the other. Compares everything from the
// first `pub fn` onward (not the whole file -- each file's own doc
// comment and `c` import line are legitimately different by design,
// since each parameterizes against its own real `@cImport` instance).
test "stays byte-for-byte identical to src/host_fn_util.zig from the first pub fn onward" {
    const allocator = std.testing.allocator;
    const this_file = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/bindgen/BindingsHostFnUtil.zig", allocator, .unlimited);
    defer allocator.free(this_file);
    const original = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/host_fn_util.zig", allocator, .unlimited);
    defer allocator.free(original);

    // Bounded to `original`'s own remaining length, not sliced to the end
    // of `this_file` -- this test's own source text lives in *this* file,
    // below the three real functions, so comparing "to the end" would
    // wrongly compare `original`'s tail (nothing) against this test's own
    // code (a real bug caught the hard way: an initial version of this
    // exact test failed against itself for exactly this reason).
    const needle = "pub fn readGuestBytes";
    const this_start = std.mem.indexOf(u8, this_file, needle) orelse return error.TestUnexpectedResult;
    const original_start = std.mem.indexOf(u8, original, needle) orelse return error.TestUnexpectedResult;
    const original_remaining = original[original_start..];
    const this_bounded = this_file[this_start .. this_start + original_remaining.len];
    try std.testing.expectEqualStrings(original_remaining, this_bounded);
}
