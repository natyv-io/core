//! Shared helpers for Extism host function callbacks: reading/writing bytes
//! through the guest's linear memory, and a generic {"error":"..."} JSON
//! response. Any capability registering host functions uses these instead
//! of re-deriving the same handle/memory-length dance -- extracted once a
//! second capability (widgets, alongside sqlite) needed the exact same code.

const std = @import("std");
const c = @import("c.zig").c;

// Returns an owned copy rather than a view into live wasm linear memory --
// that memory can move/grow, so holding a slice into it across any further
// processing (JSON parsing, allocation) is fragile regardless of root cause.
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
