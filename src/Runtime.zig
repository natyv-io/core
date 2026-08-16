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
// L1: Clay's own arena/BeginLayout/EndLayout lifecycle isn't wired into the
// render loop yet (that's L4) -- a real test below calls its
// proveTwoGrowChildrenSplitEvenly directly (see that test for why: a
// merely-imported-but-unreferenced file doesn't get its own `test` blocks
// discovered under Zig's lazy analysis, confirmed empirically). A file used
// as its own `addTest` root can't reach up to `../c.zig` (Zig 0.16's
// module-root boundary is the root file's own directory), so
// ClayLayout.zig -- like capabilities/Sqlite.zig -- is only ever reached
// transitively through this file, never as an independent test root.
const ClayLayout = @import("capabilities/ClayLayout.zig");
// L2: same reachability story as ClayLayout above -- Container.zig is only
// ever reached transitively through WidgetHost.zig, and this file's own
// test below is what actually exercises it (see that test's doc comment).
const Container = @import("widgets/Container.zig");

const Self = @This();

const max_host_functions = SqliteCapability.host_function_count + WidgetHost.host_function_count + WidgetHost.clay_host_function_count;

allocator: std.mem.Allocator,
/// `null` when conf.natyv.json's `sqlite.enabled` is false -- no connection
/// is opened at all, and `sqlite_exec`/`sqlite_query` aren't registered, so
/// a guest that wasn't granted this capability gets a normal "unknown
/// import" failure if it tries to use it, same enforcement story as
/// `allowed_hosts` for network and `widgets.*` for widget kinds.
sqlite: ?SqliteCapability,
widgets: WidgetHost,
plugin: ?*c.ExtismPlugin = null,

pub const Error = SqliteCapability.Error || error{PluginLoadFailed};

/// `db_path == null` means the app declared no SQLite capability -- see the
/// `sqlite` field doc comment.
pub fn init(allocator: std.mem.Allocator, db_path: ?[:0]const u8) Error!Self {
    const sqlite: ?SqliteCapability = if (db_path) |path| try SqliteCapability.open(allocator, path) else null;
    return .{ .allocator = allocator, .sqlite = sqlite, .widgets = .{ .allocator = allocator } };
}

pub fn deinit(self: *Self) void {
    if (self.plugin) |p| c.extism_plugin_free(p);
    if (self.sqlite) |*s| s.close();
}

/// Two-phase init: each capability's host functions capture the capability
/// itself as user_data, so registration must happen after `self` is at its
/// final stable address (i.e. after `var runtime = try Runtime.init(...)`),
/// not during construction of the returned value itself.
///
/// `clay_enabled` mirrors conf.natyv.json's `ui.backend == "clay"` (see
/// Config.UiConfig) -- only registers the natyv_clay_* functions when true,
/// same enforcement story as `widget_kinds` for the plain widget functions.
pub fn loadPlugin(self: *Self, wasm: []const u8, manifest: Manifest, widget_kinds: WidgetHost.EnabledKinds, clay_enabled: bool) Error!void {
    var funcs: [max_host_functions]?*const c.ExtismFunction = undefined;
    var n: usize = 0;
    if (self.sqlite) |*sqlite| n += sqlite.registerInto(funcs[n..]);
    n += self.widgets.registerInto(funcs[n..], widget_kinds);
    if (clay_enabled) n += self.widgets.registerClayInto(funcs[n..]);

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
    // L5: bookstore is now laid out entirely via sdk/go/ui/clay, so its
    // guest only imports natyv_clay_* (never natyv_create_button/etc) --
    // needs clay_enabled=true or plugin creation itself fails with an
    // "unknown import" error before natyv_init ever runs.
    try runtime.loadPlugin(wasm, .{}, .{}, true);
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
            .container => {},
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
    try runtime.loadPlugin(wasm, .{}, .{}, false);
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

test "Clay toolchain: two GROW children split a fixed-size parent's width evenly" {
    const result = try ClayLayout.proveTwoGrowChildrenSplitEvenly(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 150), result.child_a.width, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 150), result.child_b.width, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100), result.child_a.height, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 150), result.child_b.x, 1.0);
}

test "L2: parent_id and Clay style survive a widget-registry snapshot round trip" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try init(allocator, null);
    defer runtime.deinit();

    const parent_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 300, .h = 100 }) }, null, .{}) orelse return error.RegistryFull;

    const child_style: WidgetHost.ClayStyle = .{
        .sizing = .{
            .width = .{ .type = c.CLAY__SIZING_TYPE_GROW, .size = .{ .minMax = .{ .min = 0, .max = std.math.floatMax(f32) } } },
            .height = .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = 40, .max = 40 } } },
        },
        .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 },
        .child_gap = 6,
        .direction = c.CLAY_TOP_TO_BOTTOM,
        .child_alignment = .{ .x = c.CLAY_ALIGN_X_CENTER, .y = c.CLAY_ALIGN_Y_TOP },
    };
    const child_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }) }, parent_id, child_style) orelse return error.RegistryFull;

    var snap: [4]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 2), n);

    var found_child = false;
    var found_parent = false;
    for (snap[0..n]) |slot| {
        if (slot.id == child_id) {
            found_child = true;
            try std.testing.expectEqual(parent_id, slot.parent_id);
            try std.testing.expectEqual(@as(u16, 8), slot.clay_style.padding.left);
            try std.testing.expectEqual(@as(u16, 6), slot.clay_style.child_gap);
            try std.testing.expectEqual(c.CLAY_TOP_TO_BOTTOM, slot.clay_style.direction);
            try std.testing.expectEqual(c.CLAY__SIZING_TYPE_GROW, slot.clay_style.sizing.width.type);
        } else if (slot.id == parent_id) {
            found_parent = true;
            try std.testing.expectEqual(@as(?u32, null), slot.parent_id);
        }
    }
    try std.testing.expect(found_child);
    try std.testing.expect(found_parent);
}

test "L3: natyv_clay_create_container/_button through a real compiled guest, gated by ui.backend" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var snap: [4]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 2), n);

    var container_id: ?u32 = null;
    var button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .container => container_id = slot.id,
            .button => |b| if (std.mem.eql(u8, b.label(), "Grow Button")) {
                button_id = slot.id;
            },
            else => {},
        }
    }
    const cid = container_id orelse return error.MissingContainer;
    const bid = button_id orelse return error.MissingButton;

    for (snap[0..n]) |slot| {
        if (slot.id == cid) {
            try std.testing.expectEqual(@as(?u32, null), slot.parent_id);
            try std.testing.expectEqual(c.CLAY__SIZING_TYPE_FIXED, slot.clay_style.sizing.width.type);
            try std.testing.expectApproxEqAbs(@as(f32, 300), slot.clay_style.sizing.width.size.minMax.max, 0.01);
            try std.testing.expectEqual(@as(u16, 8), slot.clay_style.padding.left);
            try std.testing.expectEqual(@as(u16, 6), slot.clay_style.child_gap);
            try std.testing.expectEqual(c.CLAY_TOP_TO_BOTTOM, slot.clay_style.direction);
        } else if (slot.id == bid) {
            try std.testing.expectEqual(@as(?u32, cid), slot.parent_id);
            try std.testing.expectEqual(c.CLAY__SIZING_TYPE_GROW, slot.clay_style.sizing.width.type);
            try std.testing.expectEqual(c.CLAY__SIZING_TYPE_FIXED, slot.clay_style.sizing.height.type);
            try std.testing.expectApproxEqAbs(@as(f32, 40), slot.clay_style.sizing.height.size.minMax.max, 0.01);
        }
    }
}

test "L4: dirty-flag caching skips Clay recompute on an unchanged frame, real geometry gets written back" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);

    var clay_layout = try ClayLayout.init(allocator, 300, 100);
    defer clay_layout.deinit(allocator);

    // First frame: nothing computed yet, so this must run Clay for real.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    var snap: [4]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button) button_id = slot.id;
    }
    const bid = button_id orelse return error.MissingButton;

    // The button is GROW-width inside an 8px-padded 300px container -- it
    // should have real, non-zero computed geometry now, not the zeroed
    // rect it was created with in L3.
    for (snap[0..n]) |slot| {
        if (slot.id == bid) {
            try std.testing.expect(slot.widget.button.rect.w > 100);
            try std.testing.expectApproxEqAbs(@as(f32, 40), slot.widget.button.rect.h, 0.01);
        }
    }

    // Second frame: nothing changed since the first -- must skip the real
    // Clay computation entirely, not just produce the same numbers.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    // Mutating a Clay-managed widget's text bumps layout_generation (see
    // WidgetHost.setTextHostFn) -- the next frame must recompute for real.
    // Routed through the guest's own natyv_dispatch export (which calls
    // natyv_set_text on the button internally), not called directly --
    // natyv_set_text is a host function the guest imports, not a guest
    // export the host can call by name.
    var payload_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"widget_id\":{d},\"event_type\":\"Grown\"}}", .{bid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

    clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false);
    try std.testing.expectEqual(@as(usize, 2), clay_layout.recompute_count);
}
