//! Orchestrates a loaded guest plugin and the capabilities registered
//! against it: SQLite (data access) and widgets (guest-declared UI). Guest
//! exports are still called by fixed name from Zig code that already knows
//! what it wants (`initGuest`, tests); the natyv_dispatch-driven event loop
//! that drives this generically from UI clicks lives in `Dispatch.zig`.
//!
//! Tests live in `RuntimeTest.zig`, not here -- kept separate purely to
//! keep this file's own length down to its real orchestration logic (this
//! file grew a `test` block or several per widget-breadth milestone for a
//! long stretch of the project's history, and by W14 that had become the
//! overwhelming majority of the file's line count). `RuntimeTest.zig`
//! imports this file and is registered as its own `b.addTest` root in
//! build.zig, same pattern every other split-out test file
//! (Manifest.zig/Sqlite.zig/Config.zig/etc.) already uses -- the only
//! difference here is the tests were pulled into a sibling file instead of
//! living beside the code they test, since this file's own code is a
//! small, cohesive orchestration layer that doesn't need in-file tests to
//! stay readable.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const c = @import("c.zig").c;
const timing = @import("timing.zig");
const Manifest = @import("Manifest.zig");
const SqliteCapability = @import("capabilities/Sqlite.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");
const json_util = @import("json_util.zig");
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
const TextArea = @import("widgets/TextArea.zig");
const Label = @import("widgets/Label.zig");
const Checkbox = @import("widgets/Checkbox.zig");
const RadioButton = @import("widgets/RadioButton.zig");
const ProgressBar = @import("widgets/ProgressBar.zig");
// F1: same reachability story as ClayLayout above.
const Font = @import("capabilities/Font.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");
// Stage 2.2 of the binding generator arc: a build.zig-injected named
// module (mirrors `EmbeddedWasm`'s own injection) -- either the empty
// `BindingsAbsent.zig` stub (a normal dev build, `-Dhas-bindings` unset)
// or a real, `natyv bind`-generated `BindingsGenerated.zig` (written by
// `natyv build` immediately before this build runs, whenever the app
// declared any `conf.natyv.json` `bindings` entries).
const Bindings = @import("Bindings");

const Self = @This();

const max_host_functions = SqliteCapability.host_function_count + WidgetHost.host_function_count + WidgetHost.clay_host_function_count + Bindings.host_function_count;

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
/// `sqlite` field doc comment. Guarded by `build_options.sqlite_enabled`
/// (comptime, `build.zig`-injected) rather than just `db_path`'s own
/// runtime nullability -- when an app's `conf.natyv.json` never sets
/// `sqlite.enabled: true`, `natyv build` passes `-Dsqlite=false`, and this
/// comptime branch is what actually keeps `SqliteCapability.open` (and
/// everything it calls into real vendored sqlite3 code for) out of the
/// compiled binary entirely, not just unreached at runtime.
pub fn init(allocator: std.mem.Allocator, db_path: ?[:0]const u8) Error!Self {
    const sqlite: ?SqliteCapability = if (build_options.sqlite_enabled)
        (if (db_path) |path| try SqliteCapability.open(allocator, path) else null)
    else
        null;
    return .{ .allocator = allocator, .sqlite = sqlite, .widgets = .{ .allocator = allocator } };
}

pub fn deinit(self: *Self) void {
    if (self.plugin) |p| c.extism_plugin_free(p);
    if (build_options.sqlite_enabled) {
        if (self.sqlite) |*s| s.close();
    }
    self.widgets.deinit();
}

/// Two-phase init: each capability's host functions capture the capability
/// itself as user_data, so registration must happen after `self` is at its
/// final stable address (i.e. after `var runtime = try Runtime.init(...)`),
/// not during construction of the returned value itself.
///
/// `clay_enabled` mirrors conf.natyv.json's `ui.backend == "clay"` (see
/// Config.UiConfig) -- only registers the natyv_clay_* functions when true.
/// Plain widget-kind registration (`widgets.registerInto` below) is always
/// unconditional -- widgets are declarative purely through `.ntx` tag use,
/// no separate per-app opt-in (confirmed decision, 2026-08-29).
pub fn loadPlugin(self: *Self, wasm: []const u8, manifest: Manifest, clay_enabled: bool) Error!void {
    var funcs: [max_host_functions]?*const c.ExtismFunction = undefined;
    var n: usize = 0;
    if (build_options.sqlite_enabled) {
        if (self.sqlite) |*sqlite| n += sqlite.registerInto(funcs[n..]);
    }
    n += self.widgets.registerInto(funcs[n..]);
    if (clay_enabled) n += self.widgets.registerClayInto(funcs[n..]);
    // `[]?*anyopaque`, not `[]?*const c.ExtismFunction` -- see
    // `BindingsAbsent.zig`'s own doc comment on why this cross-module
    // boundary has to go through an untyped opaque pointer cast.
    n += Bindings.registerInto(@ptrCast(funcs[n..]));

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
