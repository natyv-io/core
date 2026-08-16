//! SQLite capability: registers `sqlite_exec`/`sqlite_query` as Extism host
//! functions over a single sqlite3 connection. Fully generic -- carries no
//! schema or app-specific SQL. A capability's job is to expose a resource to
//! the guest safely, not to know what the guest does with it.
//!
//! Wire contract (JSON both directions, generic, not app-specific):
//!   in:  {"sql":"...", "params":["...", ...]}   (params optional; an
//!        explicit JSON `null` is tolerated too -- some guest-language JSON
//!        marshalers, Go's encoding/json among them, encode a nil/empty
//!        slice as `null` rather than `[]`)
//!   out: {"rows_affected":N,"last_insert_id":N}       (sqlite_exec)
//!        {"rows":[{"col":"val",...}, ...]}             (sqlite_query)
//!        {"error":"..."}                                (either, on failure)

const std = @import("std");
const c = @import("../c.zig").c;
const host_fn_util = @import("../host_fn_util.zig");
const Sqlite = @import("../Sqlite.zig");

const Self = @This();

pub const Error = Sqlite.Error;
pub const host_function_count = 2;

allocator: std.mem.Allocator,
db: Sqlite,

pub fn open(allocator: std.mem.Allocator, db_path: [:0]const u8) Error!Self {
    const db = try Sqlite.open(db_path);
    return .{ .allocator = allocator, .db = db };
}

pub fn close(self: *Self) void {
    self.db.close();
}

/// Registers this capability's host functions into `funcs_out` starting at
/// index 0, returning `host_function_count`. `self` must already be at its
/// final, stable address -- the host functions capture it as `user_data`, so
/// this can only be called once `self` won't move again (e.g. after
/// `var cap = try Sqlite.open(...)`, never during construction of the
/// returned value itself).
pub fn registerInto(self: *Self, funcs_out: []?*const c.ExtismFunction) usize {
    const in_types = [_]c.ExtismValType{c.ExtismValType_I64};
    const out_types = [_]c.ExtismValType{c.ExtismValType_I64};
    funcs_out[0] = c.extism_function_new("sqlite_exec", &in_types[0], 1, &out_types[0], 1, execHostFn, self, null);
    funcs_out[1] = c.extism_function_new("sqlite_query", &in_types[0], 1, &out_types[0], 1, queryHostFn, self, null);
    return host_function_count;
}

const SqlRequest = struct {
    sql: []const u8,
    // Optional and defensively defaulted: some guest-language JSON
    // marshalers (Go's encoding/json among them) encode a nil/empty params
    // slice as `null` rather than `[]`, so this must tolerate an explicit
    // JSON null in addition to an absent field.
    params: ?[]const []const u8 = &.{},
};

fn execHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(SqlRequest, self.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const result = self.db.exec(self.allocator, parsed.value.sql, parsed.value.params orelse &.{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "exec failed: {}", .{err});
        return;
    };

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"rows_affected\":{d},\"last_insert_id\":{d}}}", .{ result.rows_affected, result.last_insert_id }) catch "{}";
    host_fn_util.writeGuestBytes(plugin, &outputs[0], json);
}

fn queryHostFn(
    plugin: ?*c.ExtismCurrentPlugin,
    inputs: [*c]const c.ExtismVal,
    n_inputs: c.ExtismSize,
    outputs: [*c]c.ExtismVal,
    n_outputs: c.ExtismSize,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = n_inputs;
    _ = n_outputs;
    const self: *Self = @ptrCast(@alignCast(user_data.?));
    const input_bytes = host_fn_util.readGuestBytes(self.allocator, plugin, &inputs[0]) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory reading input", .{});
        return;
    };
    defer self.allocator.free(input_bytes);

    const parsed = std.json.parseFromSlice(SqlRequest, self.allocator, input_bytes, .{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "bad request: {}", .{err});
        return;
    };
    defer parsed.deinit();

    const rows_json = self.db.queryToJson(self.allocator, parsed.value.sql, parsed.value.params orelse &.{}) catch |err| {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "query failed: {}", .{err});
        return;
    };
    defer self.allocator.free(rows_json);

    const response = std.fmt.allocPrint(self.allocator, "{{\"rows\":{s}}}", .{rows_json}) catch {
        host_fn_util.writeErrorJson(plugin, &outputs[0], "out of memory", .{});
        return;
    };
    defer self.allocator.free(response);
    host_fn_util.writeGuestBytes(plugin, &outputs[0], response);
}
