//! Orchestrates a loaded guest plugin and the capabilities registered
//! against it: SQLite (data access) and widgets (guest-declared UI). Guest
//! exports are still called by fixed name from Zig code that already knows
//! what it wants (`initGuest`, tests); the natyv_dispatch-driven event loop
//! that drives this generically from UI clicks lives in `Dispatch.zig`.

const std = @import("std");
const Io = std.Io;
const c = @import("c.zig").c;
const timing = @import("timing.zig");
const Manifest = @import("Manifest.zig");
const SqliteCapability = @import("capabilities/Sqlite.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");

const Self = @This();

const max_host_functions = SqliteCapability.host_function_count + WidgetHost.host_function_count;

allocator: std.mem.Allocator,
sqlite: SqliteCapability,
widgets: WidgetHost,
plugin: ?*c.ExtismPlugin = null,

pub const Error = SqliteCapability.Error || error{PluginLoadFailed};

pub fn init(allocator: std.mem.Allocator, db_path: [:0]const u8) Error!Self {
    const sqlite = try SqliteCapability.open(allocator, db_path);
    return .{ .allocator = allocator, .sqlite = sqlite, .widgets = .{ .allocator = allocator } };
}

pub fn deinit(self: *Self) void {
    if (self.plugin) |p| c.extism_plugin_free(p);
    self.sqlite.close();
}

/// Two-phase init: each capability's host functions capture the capability
/// itself as user_data, so registration must happen after `self` is at its
/// final stable address (i.e. after `var runtime = try Runtime.init(...)`),
/// not during construction of the returned value itself.
pub fn loadPlugin(self: *Self, wasm: []const u8, manifest: Manifest) Error!void {
    var funcs: [max_host_functions]?*const c.ExtismFunction = undefined;
    var n: usize = 0;
    n += self.sqlite.registerInto(funcs[n..]);
    n += self.widgets.registerInto(funcs[n..]);

    const manifest_json = manifest.build(self.allocator, wasm) catch {
        std.debug.print("[runtime] failed to build plugin manifest\n", .{});
        return error.PluginLoadFailed;
    };
    defer self.allocator.free(manifest_json);

    var errmsg: [*c]u8 = null;
    self.plugin = c.extism_plugin_new(manifest_json.ptr, manifest_json.len, &funcs[0], n, true, &errmsg);
    if (self.plugin == null) {
        std.debug.print("[runtime] failed to create plugin: {s}\n", .{errmsg});
        return error.PluginLoadFailed;
    }
    c.extism_plugin_new_error_free(errmsg);
}

/// Calls a guest export by name and returns its output bytes on success, or
/// null (after logging) on failure -- including a manifest timeout, which
/// surfaces the same way any other guest-call failure does.
///
/// `io` is required (not optional) because it's stashed on `widgets` for the
/// duration of the call -- any natyv_create_button/etc. host function the
/// guest calls during this export needs an `Io` to lock its registry with,
/// and the C ABI callback has no other way to receive one. See
/// `widgets/WidgetHost.zig`'s doc comment for the full invariant.
pub fn call(self: *Self, io: Io, name: [:0]const u8, payload: []const u8) ?[]const u8 {
    self.widgets.current_io = io;
    defer self.widgets.current_io = null;

    const start = timing.nowMs();
    const rc = c.extism_plugin_call(self.plugin, name.ptr, payload.ptr, payload.len);
    const elapsed = timing.nowMs() - start;
    if (rc != 0) {
        const err = c.extism_plugin_error(self.plugin);
        std.debug.print("[runtime] {s} FAILED after {d}ms: {s}\n", .{ name, elapsed, err });
        return null;
    }
    const len = c.extism_plugin_output_length(self.plugin);
    const data = c.extism_plugin_output_data(self.plugin);
    std.debug.print("[runtime] {s} ok ({d}ms)\n", .{ name, elapsed });
    return data[0..len];
}

/// Calls the guest's one-time UI-construction export, if it has one. Not
/// every guest needs this (M2/M3's bookstore test guest predates the
/// widget/dispatch model and has no natyv_init export at all -- Extism
/// simply reports that export as missing, treated as "nothing to build").
pub fn initGuest(self: *Self, io: Io) void {
    _ = self.call(io, "natyv_init", "");
}

test "bookstore example: guest-declared UI end to end through natyv_init + natyv_dispatch" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/bookstore/guest/bookstore.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try init(allocator, ":memory:");
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{});
    runtime.initGuest(io);

    // Drive it exactly the way main.zig's real event loop does: locate the
    // widgets the guest created (by placeholder/label, not by assuming
    // fixed ids), type into them via the same WidgetHost methods SDL text
    // input calls, and push a click the same way a real mouse click would.
    var snap: [32]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var author_id: ?u32 = null;
    var title_id: ?u32 = null;
    var genre_id: ?u32 = null;
    var add_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .textfield => |t| {
                if (std.mem.eql(u8, t.placeholder(), "Author")) author_id = slot.id;
                if (std.mem.eql(u8, t.placeholder(), "Title")) title_id = slot.id;
                if (std.mem.eql(u8, t.placeholder(), "Genre")) genre_id = slot.id;
            },
            .button => |b| {
                if (std.mem.eql(u8, b.label(), "Add Book")) add_id = slot.id;
            },
            .label => {},
        }
    }

    runtime.widgets.appendTextTo(io, author_id orelse return error.MissingAuthorField, "Frank Herbert");
    runtime.widgets.appendTextTo(io, title_id orelse return error.MissingTitleField, "Dune");
    runtime.widgets.appendTextTo(io, genre_id orelse return error.MissingGenreField, "Sci-Fi");

    var dispatch_buf: [128]u8 = undefined;
    var click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{add_id orelse return error.MissingAddButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    var found_book = false;
    var delete_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .label => |l| if (std.mem.indexOf(u8, l.text(), "Frank Herbert") != null) {
                found_book = true;
            },
            .button => |b| if (std.mem.eql(u8, b.label(), "Delete")) {
                delete_id = slot.id;
            },
            else => {},
        }
    }
    try std.testing.expect(found_book);

    click_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{delete_id orelse return error.MissingDeleteButton});
    _ = runtime.call(io, "natyv_dispatch", click_payload) orelse return error.CallFailed;

    n = runtime.widgets.snapshot(io, &snap);
    found_book = false;
    for (snap[0..n]) |slot| {
        if (slot.widget == .label and std.mem.indexOf(u8, slot.widget.label.text(), "Frank Herbert") != null) found_book = true;
    }
    try std.testing.expect(!found_book);
}

test "widget host functions: create/get/set/destroy round trip through a trivial guest" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/counter/guest/counter.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try init(allocator, ":memory:");
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{});
    runtime.initGuest(io);

    // The trivial counter guest creates exactly one button in natyv_init.
    var snap: [4]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(snap[0].widget == .button);
    const widget_id = snap[0].id;

    var dispatch_buf: [128]u8 = undefined;
    const dispatch_payload = try std.fmt.bufPrint(&dispatch_buf, "{{\"widget_id\":{d},\"event_type\":\"click\"}}", .{widget_id});

    const resp1 = runtime.call(io, "natyv_dispatch", dispatch_payload) orelse return error.CallFailed;
    try std.testing.expect(std.mem.indexOf(u8, resp1, "\"counter\":1") != null);

    const resp2 = runtime.call(io, "natyv_dispatch", dispatch_payload) orelse return error.CallFailed;
    try std.testing.expect(std.mem.indexOf(u8, resp2, "\"counter\":2") != null);
}
