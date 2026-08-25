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
