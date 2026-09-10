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
const Config = @import("Config");
const SqliteCapability = @import("capabilities/Sqlite.zig");
const TcpCapability = @import("capabilities/Tcp.zig");
const PersistCapability = @import("capabilities/Persist.zig");
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

const max_host_functions = SqliteCapability.host_function_count + TcpCapability.host_function_count + PersistCapability.host_function_count + WidgetHost.host_function_count + WidgetHost.clay_host_function_count + Bindings.host_function_count;

allocator: std.mem.Allocator,
/// `null` when conf.natyv.json's `sqlite.enabled` is false -- no connection
/// is opened at all, and `sqlite_exec`/`sqlite_query` aren't registered, so
/// a guest that wasn't granted this capability gets a normal "unknown
/// import" failure if it tries to use it, same enforcement story as
/// `allowed_hosts` for network and `widgets.*` for widget kinds.
sqlite: ?SqliteCapability,
/// `null` until `enableNetwork` is called (see its own doc comment) --
/// unlike `sqlite`, not set up during `init` itself, since this is a much
/// newer, still-partial capability (no TLS handshake yet) and every one of
/// `init`'s ~60 existing call sites across `RuntimeTest.zig` would
/// otherwise need updating for a capability none of them actually test.
tcp: ?TcpCapability = null,
/// Host-owned persisted state backing the Go SDK's `natyv.Persisted[T]` --
/// always on, like `widgets`, not gated behind a config flag the way
/// `sqlite`/`tcp` are: this is core SDK machinery every app can reach for,
/// not an opt-in capability. See `capabilities/Persist.zig`'s own doc
/// comment for the full design.
persist: PersistCapability,
widgets: WidgetHost,
plugin: ?*c.ExtismPlugin = null,
/// The pre-compiled artifact `loadPlugin` builds via `extism_compiled_plugin_new`
/// -- kept alive for the process's whole lifetime so `recycle` can cheaply
/// re-instantiate from it (`extism_plugin_new_from_compiled`) without paying
/// a full Cranelift re-JIT or re-registering the host-function array on
/// every recycle. `null` only ever transiently, before the first `loadPlugin`
/// call succeeds.
compiled: ?*c.ExtismCompiledPlugin = null,
/// Whether the loaded app implements both `natyv_checkpoint` and
/// `natyv_resume` -- detected once, right after the first successful
/// `loadPlugin`. Both are required, not either: an app implementing only
/// one is a real, silent misconfiguration otherwise. An app implementing
/// neither simply never gets recycled -- `recycle` is a no-op in that case.
can_recycle: bool = false,

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
    return .{
        .allocator = allocator,
        .sqlite = sqlite,
        .persist = PersistCapability.init(allocator),
        .widgets = .{ .allocator = allocator },
    };
}

/// Sets up the `tcp` capability (`tcp_connect`/`tcp_read`/`tcp_write`/
/// `tcp_close`) for real -- called explicitly by `main.zig` when
/// `conf.natyv.json`'s `network.enabled` is true, after `Runtime.init` but
/// before `loadPlugin` (the same "two-phase init" ordering `loadPlugin`'s
/// own doc comment already requires for every capability: registration
/// needs `self`/the capability struct at its final stable address first).
/// Never called from `RuntimeTest.zig` today -- see the `tcp` field's own
/// doc comment for why this is a separate method rather than an `init`
/// parameter.
pub fn enableNetwork(self: *Self, allowed_sockets: []const Config.AllowedSocket) void {
    self.tcp = TcpCapability.init(self.allocator, allowed_sockets);
}

pub fn deinit(self: *Self) void {
    if (self.plugin) |p| c.extism_plugin_free(p);
    if (self.compiled) |cp| c.extism_compiled_plugin_free(cp);
    if (build_options.sqlite_enabled) {
        if (self.sqlite) |*s| s.close();
    }
    if (self.tcp) |*tcp| tcp.deinit();
    self.persist.deinit();
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
///
/// Builds the host-function array and manifest once, then goes through
/// `extism_compiled_plugin_new` + `extism_plugin_new_from_compiled` rather
/// than a single `extism_plugin_new` call -- the same compiled artifact this
/// produces (`self.compiled`) is what `recycle` below re-instantiates from
/// cheaply, with no re-JIT and no re-registering the host-function array.
pub fn loadPlugin(self: *Self, wasm: []const u8, manifest: Manifest, clay_enabled: bool) Error!void {
    var funcs: [max_host_functions]?*const c.ExtismFunction = undefined;
    var n: usize = 0;
    if (build_options.sqlite_enabled) {
        if (self.sqlite) |*sqlite| n += sqlite.registerInto(funcs[n..]);
    }
    if (self.tcp) |*tcp| n += tcp.registerInto(funcs[n..]);
    n += self.persist.registerInto(funcs[n..]);
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
    self.compiled = c.extism_compiled_plugin_new(manifest_json.ptr, manifest_json.len, &funcs[0], n, true, &errmsg);
    if (self.compiled == null) {
        std.debug.print("[runtime] failed to compile plugin: {s}\n", .{errmsg});
        return error.PluginLoadFailed;
    }
    c.extism_plugin_new_error_free(errmsg);

    errmsg = null;
    self.plugin = c.extism_plugin_new_from_compiled(self.compiled, &errmsg);
    if (self.plugin == null) {
        std.debug.print("[runtime] failed to create plugin: {s}\n", .{errmsg});
        return error.PluginLoadFailed;
    }
    c.extism_plugin_new_error_free(errmsg);

    self.can_recycle = c.extism_plugin_function_exists(self.plugin, "natyv_checkpoint") and
        c.extism_plugin_function_exists(self.plugin, "natyv_resume");
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
    return self.callOn(io, self.plugin, name, payload);
}

/// `call`'s real implementation, generalized to target an explicit plugin
/// pointer rather than always `self.plugin` -- needed by `recycle` below,
/// whose safe window briefly has two live instances (the old one, still
/// `self.plugin`, and a new one not yet swapped in).
fn callOn(self: *Self, io: Io, plugin: ?*c.ExtismPlugin, name: [:0]const u8, payload: []const u8) ?[]const u8 {
    self.widgets.current_io = io;
    defer self.widgets.current_io = null;
    if (self.tcp) |*tcp| tcp.current_io = io;
    defer if (self.tcp) |*tcp| {
        tcp.current_io = null;
    };

    const start = timing.nowMs();
    const rc = c.extism_plugin_call(plugin, name.ptr, payload.ptr, payload.len);
    const elapsed = timing.nowMs() - start;
    if (rc != 0) {
        const err = c.extism_plugin_error(plugin);
        std.debug.print("[runtime] {s} FAILED after {d}ms: {s}\n", .{ name, elapsed, err });
        return null;
    }
    const len = c.extism_plugin_output_length(plugin);
    const data = c.extism_plugin_output_data(plugin);
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

/// Checkpoints the live guest instance, builds a fresh one from the same
/// compiled artifact (`self.compiled`, see `loadPlugin`), resumes it, and
/// only on success swaps it in -- never destroy-then-create, since the
/// alternative failure mode is zero live guest instances mid-process. A
/// no-op if the app never declared both `natyv_checkpoint`/`natyv_resume`
/// (see `can_recycle`), or if any step fails -- a failure keeps the current
/// instance running untouched and just logs, matching this being a
/// manually-triggered spike mechanism, not a policy that must never fail.
///
/// Must be called only between dispatches (see `Dispatch.zig`'s trigger
/// hook) -- the same single-call-in-flight window every other nested
/// host-function call in this codebase already relies on.
///
/// Returns whether the swap actually happened -- `Dispatch.zig`'s own
/// caller uses this to decide whether to push a synthetic wake dispatch
/// (see its own doc comment for why: a widget revealed from inside the
/// same natyv_resume call that built it can render with no visible style,
/// so the newly-resumed instance's own pending region reveals need a
/// genuinely separate, later real natyv_dispatch call to settle correctly
/// -- pushing one automatically means the user never has to be the one to
/// provide it by moving the mouse or clicking something).
pub fn recycle(self: *Self, io: Io) bool {
    if (!self.can_recycle) return false;

    const checkpoint_raw = self.call(io, "natyv_checkpoint", "") orelse {
        std.debug.print("[runtime] recycle: natyv_checkpoint failed, keeping current instance\n", .{});
        return false;
    };
    // Duped immediately, before touching anything else -- `checkpoint_raw`
    // borrows the old plugin's own output buffer, and creating the new
    // instance next is exactly the kind of intervening extism_plugin_call
    // this borrow has never before had to survive. See the plan's own
    // correctness note on this.
    const checkpoint = self.allocator.dupe(u8, checkpoint_raw) catch {
        std.debug.print("[runtime] recycle: OOM duping checkpoint, keeping current instance\n", .{});
        return false;
    };
    defer self.allocator.free(checkpoint);

    var errmsg: [*c]u8 = null;
    const new_plugin = c.extism_plugin_new_from_compiled(self.compiled, &errmsg);
    if (new_plugin == null) {
        std.debug.print("[runtime] recycle: failed to create new instance: {s}\n", .{errmsg});
        return false;
    }
    c.extism_plugin_new_error_free(errmsg);

    const resume_result = self.callOn(io, new_plugin, "natyv_resume", checkpoint);
    if (resume_result == null) {
        std.debug.print("[runtime] recycle: natyv_resume failed on new instance, discarding it\n", .{});
        c.extism_plugin_free(new_plugin);
        return false;
    }

    // The new instance is proven live -- only now is it safe to tear down
    // the old one and force-close whatever TCP connections it held (its own
    // handles to them lived in its now-wiped linear memory regardless).
    const old_plugin = self.plugin;
    self.plugin = new_plugin;
    if (old_plugin) |p| c.extism_plugin_free(p);
    if (self.tcp) |*tcp| tcp.registry.closeAll(io);

    std.debug.print("[runtime] recycle: swapped to a fresh guest instance, t={d}ms\n", .{c.SDL_GetTicks()});
    return true;
}
