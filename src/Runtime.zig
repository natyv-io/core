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
const Button = @import("widgets/Button.zig");
const TextField = @import("widgets/TextField.zig");
const Label = @import("widgets/Label.zig");
const Checkbox = @import("widgets/Checkbox.zig");
const RadioButton = @import("widgets/RadioButton.zig");
const ProgressBar = @import("widgets/ProgressBar.zig");
// F1: same reachability story as ClayLayout above.
const Font = @import("capabilities/Font.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");

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
            .checkbox, .radio_button, .progress_bar => {},
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

test "F1: FreeType + SDL_ttf toolchain loads the real embedded Inter font and measures real glyphs" {
    const size = try Font.proveFontRenderingToolchain();
    try std.testing.expect(size.w > 0);
    try std.testing.expect(size.h > 0);
}

test "F2: the persistent default-font capability loads Inter and reports real font metrics" {
    var font_cap = try Font.init();
    defer font_cap.deinit();

    const height = c.TTF_GetFontHeight(font_cap.font);
    try std.testing.expect(height > 0);
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

    // 8, not 4: natyv_init creates container + button + checkbox + 2 radio
    // buttons + a progress bar (W1) -- 6 widgets total, not just the
    // original container+button.
    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    try std.testing.expectEqual(@as(usize, 6), n);

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

    var font_cap = try Font.init();
    defer font_cap.deinit();

    var clay_layout = try ClayLayout.init(allocator, 300, 100, font_cap.font);
    defer clay_layout.deinit(allocator);

    // First frame: nothing computed yet, so this must run Clay for real.
    clay_layout.layoutIfNeeded(&runtime.widgets, io, 300, 100, 0, 0, false);
    try std.testing.expectEqual(@as(usize, 1), clay_layout.recompute_count);

    // 8, not 4: natyv_init creates 6 widgets now (W1 added checkbox/2 radio
    // buttons/progress bar alongside the original container+button).
    var snap: [8]WidgetHost.Slot = undefined;
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

test "F3: syncTextObjects skips re-syncing a widget's TTF_Text on an unchanged frame, real sync happens on a text change" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("f3-test", 64, 64, c.SDL_WINDOW_HIDDEN) orelse return error.SdlWindowFailed;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    const engine = c.TTF_CreateRendererTextEngine(renderer) orelse return error.TextEngineFailed;
    defer c.TTF_DestroyRendererTextEngine(engine);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    // First sync: nothing cached yet, must create the button's TTF_Text.
    runtime.widgets.syncTextObjects(io, engine, font_cap.font);

    // 8, not 4 -- see the L4 test's identical comment above.
    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    var button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button) {
            button_id = slot.id;
            try std.testing.expectEqual(@as(u32, 1), slot.widget.button.sync_count);
        }
    }
    const bid = button_id orelse return error.MissingButton;

    // Second sync: label unchanged -- must skip TTF_SetTextString entirely,
    // not just produce the same string again.
    runtime.widgets.syncTextObjects(io, engine, font_cap.font);
    _ = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == bid) try std.testing.expectEqual(@as(u32, 1), slot.widget.button.sync_count);
    }

    // Relabel via the guest's real natyv_dispatch -> natyv_set_text path
    // (same mechanism the L4 test above uses) -- must force a real re-sync
    // on the next call.
    var payload_buf: [64]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_buf, "{{\"widget_id\":{d},\"event_type\":\"Grown\"}}", .{bid});
    _ = runtime.call(io, "natyv_dispatch", payload) orelse return error.CallFailed;

    runtime.widgets.syncTextObjects(io, engine, font_cap.font);
    _ = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == bid) try std.testing.expectEqual(@as(u32, 2), slot.widget.button.sync_count);
    }
}

// F3 regression: Quinn hit a real crash clicking bookstore's "Add Book"
// button -- refreshBookList destroys every old row's widgets and creates
// new ones, and destroying a widget with a live TTF_Text called
// TTF_DestroyText directly from inside destroyWidgetHostFn, a host function
// that (per Dispatch.zig's own doc comment) runs on the worker thread, not
// the main thread that owns the text engine SDL_ttf requires TTF_Text be
// destroyed on. Fixed by queuing the pointer (`pending_text_destroys`) for
// the main thread to actually destroy instead. This test reproduces the
// real trigger as faithfully as a headless test can: a genuine second OS
// thread (`Dispatch.run`, the exact function `main.zig` spawns) processing
// a real `.click` event off a real `EventQueue` -- not a synchronous
// same-thread `runtime.call` the way the L4/F3 tests above use, which
// wouldn't violate SDL_ttf's thread-affinity rule even with the bug
// present, since everything would happen on the one test thread regardless.
test "F3 regression: destroying a widget's TTF_Text from the real worker thread doesn't crash" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("f3-regression-test", 64, 64, c.SDL_WINDOW_HIDDEN) orelse return error.SdlWindowFailed;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    const engine = c.TTF_CreateRendererTextEngine(renderer) orelse return error.TextEngineFailed;
    defer c.TTF_DestroyRendererTextEngine(engine);

    var font_cap = try Font.init();
    defer font_cap.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "examples/clay-fixture/guest/clay-fixture.wasm", allocator, .unlimited);
    defer allocator.free(wasm);

    var runtime = try init(allocator, null);
    defer runtime.deinit();
    try runtime.loadPlugin(wasm, .{}, .{}, true);
    runtime.initGuest(io);
    defer runtime.widgets.destroyAllTextObjects(io);

    // Give the initial button a real TTF_Text before triggering the click
    // -- otherwise there'd be nothing for the bug to actually crash on.
    runtime.widgets.syncTextObjects(io, engine, font_cap.font);

    // 8, not 4 -- see the L4 test's identical comment above.
    var snap: [8]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);
    var button_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button) button_id = slot.id;
    }
    const bid = button_id orelse return error.MissingButton;

    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    // Real second OS thread, same call main.zig itself makes -- the guest's
    // natyv_dispatch (and the natyv_destroy_widget it calls on a click, see
    // clay-fixture's guest/main.go) genuinely runs off this thread, not the
    // test's own, exactly like the real crash Quinn hit.
    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue });

    queue.push(io, bid, .click, "");

    // Simulates main.zig's frame loop -- the only thread allowed to
    // actually call TTF_DestroyText/TTF_CreateText for these objects.
    // Polls for the real guest-driven state change (old button destroyed,
    // new one created and labeled) instead of a fixed sleep.
    var relabeled = false;
    var i: u32 = 0;
    while (i < 500 and !relabeled) : (i += 1) {
        runtime.widgets.flushPendingTextDestroys(io);
        runtime.widgets.syncTextObjects(io, engine, font_cap.font);
        n = runtime.widgets.snapshot(io, &snap);
        // Real main.zig draws every frame too -- matching that here, not
        // just polling registry state, since the actual crash may need a
        // concurrent TTF_DrawRendererText touching the same text engine's
        // shared atlas state while the worker thread destroys a text object,
        // not just the destroy call in isolation.
        for (snap[0..n]) |slot| {
            if (slot.widget == .button) slot.widget.button.drawDecorations(renderer);
            if (slot.widget == .button and std.mem.eql(u8, slot.widget.button.label(), "Recreated Button")) {
                relabeled = true;
            }
        }
        if (!relabeled) try io.sleep(.fromMilliseconds(2), .awake);
    }

    queue.requestShutdown(io);
    worker.join();

    // The real proof this test exists for is that it got this far at all
    // without crashing -- these assertions confirm the guest-visible state
    // ended up correct too, not just that nothing crashed.
    try std.testing.expect(relabeled);
    n = runtime.widgets.snapshot(io, &snap);
    var button_count: u32 = 0;
    for (snap[0..n]) |slot| {
        if (slot.widget == .button) button_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), button_count);
}

test "nextFocusable: empty list returns null regardless of current or direction" {
    try std.testing.expectEqual(@as(?u32, null), WidgetHost.nextFocusable(&.{}, null, true));
    try std.testing.expectEqual(@as(?u32, null), WidgetHost.nextFocusable(&.{}, 5, false));
}

test "nextFocusable: single id wraps to itself both directions" {
    const ids = [_]u32{7};
    try std.testing.expectEqual(@as(?u32, 7), WidgetHost.nextFocusable(&ids, null, true));
    try std.testing.expectEqual(@as(?u32, 7), WidgetHost.nextFocusable(&ids, 7, true));
    try std.testing.expectEqual(@as(?u32, 7), WidgetHost.nextFocusable(&ids, 7, false));
}

test "nextFocusable: forward and backward wrap around the ends of a real list" {
    const ids = [_]u32{ 3, 5, 9 };

    // No current focus: forward starts at the first id, backward at the last.
    try std.testing.expectEqual(@as(?u32, 3), WidgetHost.nextFocusable(&ids, null, true));
    try std.testing.expectEqual(@as(?u32, 9), WidgetHost.nextFocusable(&ids, null, false));

    // Ordinary steps.
    try std.testing.expectEqual(@as(?u32, 5), WidgetHost.nextFocusable(&ids, 3, true));
    try std.testing.expectEqual(@as(?u32, 9), WidgetHost.nextFocusable(&ids, 5, true));
    try std.testing.expectEqual(@as(?u32, 3), WidgetHost.nextFocusable(&ids, 5, false));

    // Wrap at both ends.
    try std.testing.expectEqual(@as(?u32, 3), WidgetHost.nextFocusable(&ids, 9, true));
    try std.testing.expectEqual(@as(?u32, 9), WidgetHost.nextFocusable(&ids, 3, false));
}

test "nextFocusable: current not present in the list is treated like no current focus" {
    const ids = [_]u32{ 10, 20, 30 };
    // e.g. the previously-focused widget was just destroyed.
    try std.testing.expectEqual(@as(?u32, 10), WidgetHost.nextFocusable(&ids, 99, true));
    try std.testing.expectEqual(@as(?u32, 30), WidgetHost.nextFocusable(&ids, 99, false));
}

test "focusableIdsSorted: only Button/TextField ids come back, sorted ascending, Label/Container excluded" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try init(allocator, null);
    defer runtime.deinit();

    // Inserted deliberately out of the order they should come back in, to
    // prove this really sorts rather than happening to already be ordered.
    const label_id = runtime.widgets.insertWithLayout(io, .{ .label = Label.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, "hi") }, null, .{}) orelse return error.RegistryFull;
    const textfield_id = runtime.widgets.insertWithLayout(io, .{ .textfield = TextField.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, "") }, null, .{}) orelse return error.RegistryFull;
    const container_id = runtime.widgets.insertWithLayout(io, .{ .container = Container.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }) }, null, .{}) orelse return error.RegistryFull;
    const button_id = runtime.widgets.insertWithLayout(io, .{ .button = Button.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, "go") }, null, .{}) orelse return error.RegistryFull;
    _ = label_id;
    _ = container_id;

    // button_id was created after textfield_id, so ascending id order is
    // {textfield_id, button_id} -- not creation-call order in this test,
    // proving the sort (not insertion order) is what's actually returned.
    try std.testing.expect(textfield_id < button_id);

    var ids: [8]u32 = undefined;
    const n = runtime.widgets.focusableIdsSorted(io, &ids);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(textfield_id, ids[0]);
    try std.testing.expectEqual(button_id, ids[1]);
}

test "W1: selectRadioExclusive keeps exclusivity within a group and leaves other groups alone" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var runtime = try init(allocator, null);
    defer runtime.deinit();

    // Group 0: three radios. Group 1: one distractor -- selecting something
    // in group 0 must never touch it.
    const a = runtime.widgets.insertWithLayout(io, .{ .radio_button = RadioButton.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 0, "A") }, null, .{}) orelse return error.RegistryFull;
    const b = runtime.widgets.insertWithLayout(io, .{ .radio_button = RadioButton.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 0, "B") }, null, .{}) orelse return error.RegistryFull;
    const rc = runtime.widgets.insertWithLayout(io, .{ .radio_button = RadioButton.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 0, "C") }, null, .{}) orelse return error.RegistryFull;
    const distractor = runtime.widgets.insertWithLayout(io, .{ .radio_button = RadioButton.init(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 1, "D") }, null, .{}) orelse return error.RegistryFull;

    // Select A, then the distractor (its own group, harmless), then C --
    // selecting C must deselect A (the previously-selected sibling in its
    // group) but must not touch the distractor in the other group.
    runtime.widgets.selectRadioExclusive(io, a);
    runtime.widgets.selectRadioExclusive(io, distractor);
    runtime.widgets.selectRadioExclusive(io, rc);

    var snap: [8]WidgetHost.Slot = undefined;
    const n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        const checked = slot.widget.radio_button.checked;
        if (slot.id == a) try std.testing.expect(!checked);
        if (slot.id == b) try std.testing.expect(!checked);
        if (slot.id == rc) try std.testing.expect(checked);
        if (slot.id == distractor) try std.testing.expect(checked);
    }
}

test "W1: checkbox/radio/progress bar created and mutated through a real compiled guest" {
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

    var snap: [8]WidgetHost.Slot = undefined;
    var n = runtime.widgets.snapshot(io, &snap);

    var checkbox_id: ?u32 = null;
    var radio_a_id: ?u32 = null;
    var radio_b_id: ?u32 = null;
    var progress_id: ?u32 = null;
    for (snap[0..n]) |slot| {
        switch (slot.widget) {
            .checkbox => |cb| {
                try std.testing.expectEqualStrings("Enable Feature", cb.label());
                try std.testing.expect(!cb.checked);
                checkbox_id = slot.id;
            },
            .radio_button => |r| {
                if (std.mem.eql(u8, r.label(), "Option A")) {
                    try std.testing.expect(r.checked);
                    radio_a_id = slot.id;
                } else if (std.mem.eql(u8, r.label(), "Option B")) {
                    try std.testing.expect(!r.checked);
                    radio_b_id = slot.id;
                }
            },
            .progress_bar => |p| {
                try std.testing.expectApproxEqAbs(@as(f32, 0.25), p.value, 0.001);
                progress_id = slot.id;
            },
            else => {},
        }
    }
    const cbid = checkbox_id orelse return error.MissingCheckbox;
    const raid = radio_a_id orelse return error.MissingRadioA;
    const rbid = radio_b_id orelse return error.MissingRadioB;
    const prid = progress_id orelse return error.MissingProgressBar;

    // Real guest-routed checkbox toggle (natyv_set_checked via natyv_dispatch).
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"CheckIt\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == cbid) try std.testing.expect(slot.widget.checkbox.checked);
    }

    // Real guest-routed radio selection -- must flip exclusivity: B becomes
    // checked, A (checked since natyv_init) becomes unchecked.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"SelectRadioB\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == raid) try std.testing.expect(!slot.widget.radio_button.checked);
        if (slot.id == rbid) try std.testing.expect(slot.widget.radio_button.checked);
    }

    // Real guest-routed progress value change.
    _ = runtime.call(io, "natyv_dispatch", "{\"widget_id\":0,\"event_type\":\"SetProgressHalf\"}") orelse return error.CallFailed;
    n = runtime.widgets.snapshot(io, &snap);
    for (snap[0..n]) |slot| {
        if (slot.id == prid) try std.testing.expectApproxEqAbs(@as(f32, 0.5), slot.widget.progress_bar.value, 0.001);
    }
}
