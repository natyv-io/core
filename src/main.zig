const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("Config.zig");
const Manifest = @import("Manifest.zig");
const Runtime = @import("Runtime.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");
const Container = @import("widgets/Container.zig");
const Label = @import("widgets/Label.zig");
const Button = @import("widgets/Button.zig");
const timing = @import("timing.zig");
const ClayLayout = @import("capabilities/ClayLayout.zig");
const Font = @import("capabilities/Font.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");
const FloatingOrder = @import("FloatingOrder.zig");
const WindowManager = @import("WindowManager.zig");
const FrameLoop = @import("FrameLoop.zig");

const max_widgets_on_screen = WidgetHost.max_widgets;

fn fixedAxis(v: f32) c.Clay_SizingAxis {
    return .{ .type = c.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = v, .max = v } } };
}

/// Multi-window Stage 3 dev scaffolding: inserts a hardcoded second
/// window's own content directly into the registry (a `window_root`
/// Container holding a Label and a "close this window" Button) -- there's
/// no guest-facing wire surface for windows yet (that's Stage 4), so this
/// stands in for what a real guest's `natyv_clay_create_window` call plus
/// its own child widgets would produce. Deleted once Stage 4 supersedes it.
/// Returns the window_root's own widget id and the close button's widget
/// id, both needed by the caller to construct the real `WindowContext`.
fn createDevWindowContent(widgets: *WidgetHost, io: std.Io) !struct { root_id: u32, close_button_id: u32 } {
    const zero_rect = std.mem.zeroes(c.SDL_FRect);
    // A `window_root` slot is never itself opened as a Clay element in its
    // own window's context -- only its children attach, directly under that
    // context's synthetic top-level root (see ClayLayout.layoutIfNeeded's
    // own doc comment) -- so `direction`/`padding`/`child_gap` set *here*
    // would be silently inert. A real child Container carries those instead,
    // same as a guest composing its own layout would have to.
    const root_id = widgets.insertWithLayout(io, .{ .container = Container.init(zero_rect, false) }, null, .{
        .window_root = true,
        .sizing = .{ .width = fixedAxis(400), .height = fixedAxis(300) },
    }) orelse return error.WidgetRegistryFull;
    const content_id = widgets.insertWithLayout(io, .{ .container = Container.init(zero_rect, true) }, root_id, .{
        .sizing = .{ .width = fixedAxis(400), .height = fixedAxis(300) },
        .direction = c.CLAY_TOP_TO_BOTTOM,
        .child_gap = 12,
        .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
    }) orelse return error.WidgetRegistryFull;
    _ = widgets.insertWithLayout(io, .{ .label = Label.init(zero_rect, "Second window (dev)") }, content_id, .{
        .sizing = .{ .width = fixedAxis(360), .height = fixedAxis(24) },
    }) orelse return error.WidgetRegistryFull;
    const close_button_id = widgets.insertWithLayout(io, .{ .button = Button.init(zero_rect, "Close this window") }, content_id, .{
        .sizing = .{ .width = fixedAxis(180), .height = fixedAxis(36) },
    }) orelse return error.WidgetRegistryFull;
    return .{ .root_id = root_id, .close_button_id = close_button_id };
}

/// Multi-window Stage 3: the id of whichever open window `wid` names, or
/// `null` if none currently open matches (e.g. a stray event for a window
/// that was already torn down this same frame).
fn findWindowIndex(windows: []const WindowManager.WindowContext, wid: c.SDL_WindowID) ?usize {
    for (windows, 0..) |wctx, i| {
        if (c.SDL_GetWindowID(wctx.window) == wid) return i;
    }
    return null;
}

// M7: app identity, wasm location, and every capability an app needs
// (SQLite, network + allowed hosts, which widget kinds) now come from
// conf.natyv.json instead of CLI arguments -- a real install shouldn't
// require remembering flags to run someone else's app correctly. The one
// remaining CLI argument is the config file's own path, defaulting to
// `conf.natyv.json` in the current directory, purely for dev convenience
// (pointing at a different example without `cd`ing into it first).
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = init.minimal.args.vector;
    const config_path: []const u8 = if (argv.len > 1) std.mem.span(argv[1]) else "conf.natyv.json";

    const config = Config.load(allocator, io, config_path) catch |err| {
        std.debug.print("[main] failed to load {s}: {}\n", .{ config_path, err });
        return err;
    };
    defer config.deinit();

    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    const app_wasm_path = try std.fs.path.join(allocator, &.{ config_dir, config.value.app_wasm });
    defer allocator.free(app_wasm_path);

    const app_name_z = try allocator.dupeZ(u8, config.value.name);
    defer allocator.free(app_name_z);

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    // F2: the bundled default font (Inter) -- unconditional, not gated by
    // conf.natyv.json, since every app gets it regardless (see the
    // font-rendering plan). Not consumed yet -- that's F3, which swaps
    // every SDL_RenderDebugText call site over to real glyph rendering.
    var default_font = try Font.init();
    defer default_font.deinit();

    var db_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var db_path: ?[:0]const u8 = null;
    if (config.value.sqlite.enabled) {
        const pref_path_c = c.SDL_GetPrefPath("natyv", app_name_z.ptr) orelse {
            std.debug.print("SDL_GetPrefPath failed: {s}\n", .{c.SDL_GetError()});
            return error.PrefPathFailed;
        };
        defer c.SDL_free(pref_path_c);
        const pref_path = std.mem.span(pref_path_c);
        db_path = std.fmt.bufPrintZ(&db_path_buf, "{s}{s}", .{ pref_path, config.value.sqlite.filename }) catch {
            std.debug.print("[main] db path too long\n", .{});
            return error.PathTooLong;
        };
    }

    std.debug.print("[main] app: {s} ({s})\n[main] database: {s}\n", .{ config.value.name, app_wasm_path, db_path orelse "(sqlite disabled)" });

    const wasm = std.Io.Dir.cwd().readFileAlloc(io, app_wasm_path, allocator, .unlimited) catch |err| {
        std.debug.print("[main] failed to read {s}: {}\n", .{ app_wasm_path, err });
        return err;
    };
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, db_path);
    defer runtime.deinit();

    const manifest: Manifest = .{ .allowed_hosts = if (config.value.network.enabled) config.value.network.allowed_hosts else &.{} };
    const widget_kinds: WidgetHost.EnabledKinds = .{
        .button = config.value.widgets.button,
        .textfield = config.value.widgets.textfield,
        .textarea = config.value.widgets.textarea,
        .label = config.value.widgets.label,
        .checkbox = config.value.widgets.checkbox,
        .toggle = config.value.widgets.toggle,
        .radio_button = config.value.widgets.radio_button,
        .progress_bar = config.value.widgets.progress_bar,
        .slider = config.value.widgets.slider,
        .divider = config.value.widgets.divider,
        .badge = config.value.widgets.badge,
        .numeric_stepper = config.value.widgets.numeric_stepper,
        .segmented_control = config.value.widgets.segmented_control,
    };
    const clay_enabled = if (config.value.ui.backend) |backend| std.mem.eql(u8, backend, "clay") else false;
    try runtime.loadPlugin(wasm, manifest, widget_kinds, clay_enabled);
    runtime.initGuest(io);

    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue });

    // Multi-window Stage 3: every open window's own real OS resources +
    // per-window frame state now lives in this array instead of a single
    // set of bare locals -- `windows[0]` is always the original startup
    // window (`root_widget_id == null`), constructed the same way every
    // other window is (via `WindowManager.createWindowContext`) rather than
    // as a special case.
    var windows: [WindowManager.max_open_windows]WindowManager.WindowContext = undefined;
    var window_count: usize = 0;
    windows[0] = try WindowManager.createWindowContext(allocator, app_name_z, 900, 700, default_font.font, clay_enabled, null);
    window_count += 1;

    // Stage 3 dev scaffolding -- see createDevWindowContent's own doc
    // comment. Only meaningful with the Clay backend enabled (a window root
    // is a Clay-managed marker widget); skipped otherwise, same "capability
    // you didn't declare costs you nothing" story every other optional
    // capability in this file already follows.
    if (clay_enabled) {
        const dev_content = try createDevWindowContent(&runtime.widgets, io);
        windows[window_count] = try WindowManager.createWindowContext(allocator, "Second Window (dev)", 400, 300, default_font.font, clay_enabled, dev_content.root_id);
        windows[window_count].dev_close_button_id = dev_content.close_button_id;
        window_count += 1;
    }

    const arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    defer if (arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
    const pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    defer if (pointer_cursor) |cur| c.SDL_DestroyCursor(cur);

    std.debug.print("[main] window open -- close it to quit.\n", .{});

    var running = true;

    // Multi-window Stage 3: scratch buffers for each open window's own
    // widget subset (see FloatingOrder.windowSubset), computed once per
    // frame and reused for both this frame's event dispatch and its draw
    // pass -- same "declared once before the loop, reused every frame"
    // precedent the original single-window body's own `widget_snapshot`/
    // `clip_rects`/`is_floating` locals already set.
    var per_window_slots: [WindowManager.max_open_windows][max_widgets_on_screen]WidgetHost.Slot = undefined;
    var per_window_slot_count: [WindowManager.max_open_windows]usize = [_]usize{0} ** WindowManager.max_open_windows;
    var per_window_is_floating: [WindowManager.max_open_windows][max_widgets_on_screen]bool = undefined;
    var per_window_topmost_modal: [WindowManager.max_open_windows]?u32 = [_]?u32{null} ** WindowManager.max_open_windows;

    while (running) {
        // Per-window Clay layout pass -- must run before this frame's
        // registry-wide maintenance below, so a real recompute's freshly
        // written-back rects are what the rest of the frame sees. See
        // FrameLoop.layoutWindow's own doc comment for why mouse position
        // now comes from one shared SDL_GetGlobalMouseState call instead of
        // SDL_GetMouseState.
        var global_mouse_x: f32 = undefined;
        var global_mouse_y: f32 = undefined;
        const global_buttons = c.SDL_GetGlobalMouseState(&global_mouse_x, &global_mouse_y);
        for (windows[0..window_count]) |*wctx| {
            if (wctx.pending_close) continue;
            FrameLoop.layoutWindow(&runtime.widgets, io, wctx, global_mouse_x, global_mouse_y, global_buttons);
        }

        // F3: a guest destroying a widget can't destroy its TTF_Text right
        // then -- see WidgetHost.pending_text_destroys' own doc comment.
        // Registry-wide, not per-window: a single queue drained once per
        // frame regardless of how many windows are open.
        runtime.widgets.flushPendingTextDestroys(io);

        // W7: destroys any widget (and cascades to its descendants) whose
        // expiry has passed -- registry-wide, same reasoning as above.
        runtime.widgets.destroyExpiredWidgets(io, timing.nowMs());

        // F3: per-window text sync -- each window's own TTF_TextEngine is
        // renderer-specific (see syncTextObjects' own doc comment), so this
        // can't be one registry-wide call the way flush/destroy-expired
        // above are. `allowed_ids` comes from a structural snapshot taken
        // just for this -- parent_id/window_root don't change from text
        // syncing itself, so this doesn't need to be this frame's *final*
        // snapshot.
        {
            var struct_snap: [max_widgets_on_screen]WidgetHost.Slot = undefined;
            const struct_n = runtime.widgets.snapshot(io, &struct_snap);
            for (windows[0..window_count]) |*wctx| {
                if (wctx.pending_close) continue;
                var ids: [max_widgets_on_screen]u32 = undefined;
                const idn = FloatingOrder.windowSubset(struct_snap[0..struct_n], wctx.root_widget_id, &ids);
                runtime.widgets.syncTextObjects(io, wctx.text_engine, default_font.font, ids[0..idn]);
            }
        }

        var widget_snapshot: [max_widgets_on_screen]WidgetHost.Slot = undefined;
        const widget_count = runtime.widgets.snapshot(io, &widget_snapshot);

        // Scroll-into-view / file picker -- both anchored to the original
        // startup window, see FrameLoop.drainGlobalPending's own doc
        // comment.
        FrameLoop.drainGlobalPending(&runtime.widgets, io, &queue, windows[0].window, widget_snapshot[0..widget_count]);

        // Each window's own widget subset for this frame -- computed once,
        // reused by both this frame's event dispatch below and its draw
        // pass afterward (mirrors the original single-window body's own
        // "is_floating/topmost_modal computed once before the event loop"
        // ordering).
        for (windows[0..window_count], 0..) |wctx, i| {
            if (wctx.pending_close) {
                per_window_slot_count[i] = 0;
                continue;
            }
            var ids: [max_widgets_on_screen]u32 = undefined;
            const idn = FloatingOrder.windowSubset(widget_snapshot[0..widget_count], wctx.root_widget_id, &ids);
            var n: usize = 0;
            for (widget_snapshot[0..widget_count]) |s| {
                if (FrameLoop.containsId(ids[0..idn], s.id)) {
                    per_window_slots[i][n] = s;
                    n += 1;
                }
            }
            per_window_slot_count[i] = n;
            FloatingOrder.computeIsFloating(per_window_slots[i][0..n], per_window_is_floating[i][0..n]);
            per_window_topmost_modal[i] = FloatingOrder.topmostModalRoot(per_window_slots[i][0..n]);
        }

        // Tree view: a real `.scroll` push for each scroll container this
        // frame's layout pass reported, per window.
        for (windows[0..window_count]) |*wctx| {
            if (wctx.pending_close) continue;
            FrameLoop.pushScrollEvents(&queue, io, wctx, widget_snapshot[0..widget_count]);
        }

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
                    if (findWindowIndex(windows[0..window_count], event.window.windowID)) |idx| {
                        // The original startup window closing always quits,
                        // unconditionally -- SDL's own
                        // SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE default no
                        // longer covers this once a second window can exist
                        // (it only fires QUIT when the *last* window
                        // closes), so this is now handled explicitly.
                        if (windows[idx].root_widget_id == null) {
                            running = false;
                        } else {
                            windows[idx].pending_close = true;
                        }
                    }
                },
                else => {
                    if (FrameLoop.windowIDOf(event)) |wid| {
                        if (findWindowIndex(windows[0..window_count], wid)) |idx| {
                            if (!windows[idx].pending_close) {
                                FrameLoop.handleEvent(&runtime.widgets, io, &queue, &windows[idx], per_window_slots[idx][0..per_window_slot_count[idx]], per_window_is_floating[idx][0..per_window_slot_count[idx]], per_window_topmost_modal[idx], event);
                            }
                        }
                    }
                },
            }
        }

        for (windows[0..window_count], 0..) |*wctx, i| {
            if (wctx.pending_close) continue;
            FrameLoop.drawWindow(&runtime.widgets, io, &queue, wctx, per_window_slots[i][0..per_window_slot_count[i]], per_window_is_floating[i][0..per_window_slot_count[i]], per_window_topmost_modal[i], arrow_cursor, pointer_cursor);
        }

        // Tear down any window that requested closing this frame (an OS
        // close request, or -- Stage 3 dev scaffolding -- its own close
        // button), after drawing so nothing this frame still needed its
        // resources. Backwards so removing an index by shifting the array
        // down doesn't skip the next one.
        var wi = window_count;
        while (wi > 0) {
            wi -= 1;
            if (!windows[wi].pending_close) continue;
            runtime.widgets.destroyWindowSubtree(io, windows[wi].root_widget_id.?);
            WindowManager.destroyWindowContext(&windows[wi], allocator);
            var shift = wi;
            while (shift + 1 < window_count) : (shift += 1) windows[shift] = windows[shift + 1];
            window_count -= 1;
        }
    }

    std.debug.print("[main] window closed -- shutting down\n", .{});
    queue.requestShutdown(io);
    worker.join();

    // Multi-window Stage 3: tears down every still-open window's OS
    // resources, replacing today's single set of `defer`s now that more
    // than one can exist. SDL_ttf requires every TTF_Text be destroyed
    // before the engine that made it -- destroyAllTextObjects doesn't care
    // which engine created a given text object (TTF_DestroyText itself
    // takes no engine argument), so one registry-wide call before tearing
    // down every window's own engine satisfies that ordering for all of
    // them at once.
    runtime.widgets.destroyAllTextObjects(io);
    for (windows[0..window_count]) |*wctx| WindowManager.destroyWindowContext(wctx, allocator);

    std.debug.print("[main] clean shutdown\n", .{});
}
