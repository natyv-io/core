const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("Config");
const Manifest = @import("Manifest.zig");
const Runtime = @import("Runtime.zig");
const build_options = @import("build_options");
const EmbeddedWasm = @import("EmbeddedWasm");
const WidgetHost = @import("widgets/WidgetHost.zig");
const timing = @import("timing.zig");
const ClayLayout = @import("capabilities/ClayLayout.zig");
const Font = @import("capabilities/Font.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");
const FloatingOrder = @import("FloatingOrder.zig");
const WindowManager = @import("WindowManager.zig");
const FrameLoop = @import("FrameLoop.zig");
const Logging = @import("Logging.zig");

const max_widgets_on_screen = WidgetHost.max_widgets;

/// The id of whichever open window `wid` (an `SDL_WindowID`) names, or
/// `null` if none currently open matches (e.g. a stray event for a window
/// that was already torn down this same frame).
fn findWindowIndex(windows: []const WindowManager.WindowContext, wid: c.SDL_WindowID) ?usize {
    for (windows, 0..) |wctx, i| {
        if (c.SDL_GetWindowID(wctx.window) == wid) return i;
    }
    return null;
}

/// Multi-window Stage 4: the counterpart to `findWindowIndex` above, keyed
/// by a window's own `root_widget_id` instead of its real `SDL_WindowID` --
/// what `takePendingWindowTeardowns` (a widget id, not an OS window handle)
/// needs to find which open `WindowContext` a guest's `natyv_destroy_window`
/// call actually refers to.
fn findWindowIndexByRoot(windows: []const WindowManager.WindowContext, root_widget_id: u32) ?usize {
    for (windows, 0..) |wctx, i| {
        if (wctx.root_widget_id == root_widget_id) return i;
    }
    return null;
}

/// Removes `windows[idx]` by shifting every later entry down one slot --
/// the shared shape both the teardown-draining step and (at shutdown) any
/// other window-removal path use, so `window_count` and array contents
/// never drift out of sync with each other.
fn removeWindow(windows: []WindowManager.WindowContext, window_count: *usize, idx: usize) void {
    var shift = idx;
    while (shift + 1 < window_count.*) : (shift += 1) windows[shift] = windows[shift + 1];
    window_count.* -= 1;
}

// M7: app identity, wasm location, and every capability an app needs
// (SQLite, network + allowed hosts, which widget kinds) now come from
// conf.natyv.json instead of CLI arguments -- a real install shouldn't
// require remembering flags to run someone else's app correctly. The one
// remaining CLI argument is the config file's own path, defaulting to
// `conf.natyv.json` in the current directory, purely for dev convenience
// (pointing at a different example without `cd`ing into it first) --
// only ever consulted for a local, non-embedded dev build (see below);
// a real bundled `.app` always uses its own embedded config regardless
// of argv, since it can't rely on any particular cwd at launch anyway.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // `Args.Iterator.initAllocator`, not raw `argv[i]` indexing --
    // `init.minimal.args.vector` isn't an array of C-string pointers on
    // every target the way it is on POSIX: on Windows it's the single raw
    // UTF-16 command-line string the OS actually hands a process, which
    // `std.mem.span`-style indexing can't even typecheck against. The
    // iterator does the real cross-platform (and Windows-specific)
    // parsing so this file doesn't have to.
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iter.deinit();
    _ = arg_iter.skip(); // argv[0] is this executable's own path.
    const config_path: []const u8 = arg_iter.next() orelse "conf.natyv.json";

    // Mirrors the wasm dispatch further below exactly (same
    // `build_options.embed_app_wasm` flag, same "embedded wins
    // unconditionally" shape): Finder/Launch Services never sets a
    // bundled `.app`'s cwd to its own bundle directory, so a real
    // distributable build can't rely on a cwd-relative disk read at all
    // -- confirmed the hard way when the first real `.app` this project
    // built failed to launch from the Dock with a plain `FileNotFound`
    // on `conf.natyv.json`. `EmbeddedWasm.config_bytes` is baked in by
    // `Bundle.zig` at the same point it already embeds the app's wasm.
    const config = if (build_options.embed_app_wasm)
        Config.parseBytes(allocator, EmbeddedWasm.config_bytes) catch |err| {
            std.debug.print("[main] failed to load embedded config: {}\n", .{err});
            return err;
        }
    else
        Config.load(allocator, io, config_path) catch |err| {
            std.debug.print("[main] failed to load {s}: {}\n", .{ config_path, err });
            return err;
        };
    defer config.deinit();

    // Only ever consulted in the non-embedded (local dev/testing) branch
    // below -- `<name>.wasm` under `guest/`, the same convention the now-
    // removed `app_wasm` field always held in practice.
    const config_dir = std.fs.path.dirname(config_path) orelse ".";
    const wasm_filename = try config.value.wasmFilename(allocator);
    defer allocator.free(wasm_filename);
    const app_wasm_path = try std.fs.path.join(allocator, &.{ config_dir, "guest", wasm_filename });
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

    try Logging.init(io, config.value.logging, app_name_z);
    defer Logging.deinit();

    // `.ntx` tooling Stage 7's bundling step: a binary built via
    // `zig build -Dembed-app-wasm=true` (only ever `natyv build` itself)
    // uses the wasm embedded at compile time instead of reading
    // `app_wasm` from disk -- `wasm_buf` (and its `defer`) only exists to
    // free the runtime-loaded copy; `EmbeddedWasm.bytes` is static
    // program data and must never be passed to `allocator.free`.
    var wasm_buf: ?[]const u8 = null;
    defer if (wasm_buf) |w| allocator.free(w);

    const wasm: []const u8 = if (build_options.embed_app_wasm) blk: {
        std.debug.print("[main] app: {s} (embedded wasm)\n[main] database: {s}\n", .{ config.value.name, db_path orelse "(sqlite disabled)" });
        break :blk EmbeddedWasm.bytes;
    } else blk: {
        std.debug.print("[main] app: {s} ({s})\n[main] database: {s}\n", .{ config.value.name, app_wasm_path, db_path orelse "(sqlite disabled)" });
        const w = std.Io.Dir.cwd().readFileAlloc(io, app_wasm_path, allocator, .unlimited) catch |err| {
            std.debug.print("[main] failed to read {s}: {}\n", .{ app_wasm_path, err });
            return err;
        };
        wasm_buf = w;
        break :blk w;
    };

    var runtime = try Runtime.init(allocator, db_path);
    defer runtime.deinit();
    if (config.value.network.enabled) runtime.enableNetwork(config.value.network.tcp.allowed_sockets);
    // Real OS sockets need a real `Io` to close gracefully (see
    // TcpRegistry.closeAll's own doc comment for why Runtime.deinit alone
    // can't do this) -- `io` is still alive here, right before it stops
    // being so, so this is the right place for it.
    defer if (runtime.tcp) |*tcp| tcp.registry.closeAll(io);

    const manifest: Manifest = .{ .allowed_hosts = if (config.value.network.enabled) config.value.network.http.allowed_hosts else &.{} };
    const clay_enabled = if (config.value.ui.backend) |backend| std.mem.eql(u8, backend, "clay") else false;
    try runtime.loadPlugin(wasm, manifest, clay_enabled);
    runtime.initGuest(io);

    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue });

    // Multi-window: every open window's own real OS resources + per-window
    // frame state lives in this array -- `windows[0]` is always the original
    // startup window (`root_widget_id == null`), constructed the same way
    // every other window is (via `WindowManager.createWindowContext`) rather
    // than as a special case. Every window after it is opened/closed by a
    // guest's own `natyv_clay_create_window`/`natyv_destroy_window` calls,
    // drained from `WidgetHost`'s pending queues each frame below.
    var windows: [WindowManager.max_open_windows]WindowManager.WindowContext = undefined;
    var window_count: usize = 0;
    windows[0] = try WindowManager.createWindowContext(allocator, app_name_z, 900, 700, default_font.font, clay_enabled, null);
    window_count += 1;

    const arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    defer if (arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
    const pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    defer if (pointer_cursor) |cur| c.SDL_DestroyCursor(cur);

    std.debug.print("[main] window open -- close it to quit.\n", .{});

    var running = true;

    // Scratch buffers for each open window's own widget subset (see
    // FloatingOrder.windowSubset), computed once per frame and reused for
    // both this frame's event dispatch and its draw pass -- same "declared
    // once before the loop, reused every frame" precedent the original
    // single-window body's own `widget_snapshot`/`clip_rects`/`is_floating`
    // locals already set.
    var per_window_slots: [WindowManager.max_open_windows][max_widgets_on_screen]WidgetHost.Slot = undefined;
    var per_window_slot_count: [WindowManager.max_open_windows]usize = [_]usize{0} ** WindowManager.max_open_windows;
    var per_window_is_floating: [WindowManager.max_open_windows][max_widgets_on_screen]bool = undefined;
    var per_window_topmost_modal: [WindowManager.max_open_windows]?u32 = [_]?u32{null} ** WindowManager.max_open_windows;

    while (running) {
        // Logging: a no-op when disabled. Extism only *buffers* guest log
        // lines internally until this runs -- see Logging.zig's own doc
        // comment for why draining once per frame (not per dispatch) is
        // the right cadence.
        Logging.drain();

        // F3: a guest destroying a widget can't destroy its TTF_Text right
        // then -- see WidgetHost.pending_text_destroys' own doc comment.
        // Registry-wide, not per-window: a single queue drained once per
        // frame regardless of how many windows are open.
        //
        // Multi-window Stage 5 fix: this must run *before* the window-set
        // draining step below, not after -- draining a window teardown
        // calls WindowManager.destroyWindowContext, which destroys that
        // window's own TTF_TextEngine. SDL_ttf requires every TTF_Text be
        // destroyed before the engine that created it; `natyv_destroy_window`
        // already queued that window's own widgets' TTF_Text pointers here
        // (via destroyWindowSubtree, synchronously, before it ever queues
        // the teardown itself -- see queueWindowTeardown's own doc comment),
        // so flushing first is what actually satisfies that ordering.
        // Reversed (as this originally shipped) it was a real, confirmed
        // crash: `TTF_DestroyText` called against an already-destroyed
        // engine, "Segmentation fault... aborting due to recursive panic",
        // caught by clicking a window's own Close button live, not by
        // inspection.
        runtime.widgets.flushPendingTextDestroys(io);

        // Multi-window Stage 4: settle this frame's open-window set --
        // drain any guest-requested teardown, then any guest-requested
        // creation -- before anything else this frame touches `windows[]`,
        // so a just-opened window gets a real layout/draw pass this same
        // frame and a just-closed one doesn't.
        {
            var teardown_ids: [WidgetHost.max_pending_window_requests]u32 = undefined;
            const teardown_n = runtime.widgets.takePendingWindowTeardowns(io, &teardown_ids);
            for (teardown_ids[0..teardown_n]) |wid| {
                if (findWindowIndexByRoot(windows[0..window_count], wid)) |idx| {
                    WindowManager.destroyWindowContext(&windows[idx], allocator);
                    removeWindow(&windows, &window_count, idx);
                }
            }

            var requests: [WidgetHost.max_pending_window_requests]WidgetHost.PendingWindowRequest = undefined;
            const request_n = runtime.widgets.takePendingWindowRequests(io, &requests);
            for (requests[0..request_n]) |req| {
                if (window_count >= WindowManager.max_open_windows) {
                    std.debug.print("[main] too many open windows, dropping window request for widget {d}\n", .{req.widget_id});
                    continue;
                }
                var title_buf: [65]u8 = undefined;
                @memcpy(title_buf[0..req.title_len], req.title_buf[0..req.title_len]);
                title_buf[req.title_len] = 0;
                const title_z: [:0]const u8 = title_buf[0..req.title_len :0];
                windows[window_count] = WindowManager.createWindowContext(allocator, title_z, req.width, req.height, default_font.font, clay_enabled, req.widget_id) catch |err| {
                    std.debug.print("[main] failed to create window for widget {d}: {}\n", .{ req.widget_id, err });
                    continue;
                };
                window_count += 1;
            }
        }

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
            FrameLoop.layoutWindow(&runtime.widgets, io, wctx, global_mouse_x, global_mouse_y, global_buttons);
        }

        // W7: destroys any widget (and cascades to its descendants) whose
        // expiry has passed -- registry-wide, same reasoning as the flush
        // above. Its own newly-queued text destroys (if any) aren't flushed
        // until *next* frame's flush call above -- same one-frame-max
        // latency `natyv_destroy_widget`'s own worker-thread queued path
        // already has, harmless since nothing tears down a text engine
        // between here and then this same frame.
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
                        // closes), so this is handled explicitly. Any other
                        // window just gets a `.window_close_requested` event
                        // pushed to its own root widget -- the host doesn't
                        // destroy anything on its own; if the guest never
                        // calls `natyv_destroy_window` in response, the
                        // window just stays open. See EventType's own doc
                        // comment.
                        if (windows[idx].root_widget_id) |root_id| {
                            const snap = widget_snapshot[0..widget_count];
                            queue.push(io, root_id, .window_close_requested, "", FloatingOrder.surfaceIdFor(snap, WidgetHost.SnapshotIndex.build(snap), root_id));
                        } else {
                            running = false;
                        }
                    }
                },
                else => {
                    if (FrameLoop.windowIDOf(event)) |wid| {
                        if (findWindowIndex(windows[0..window_count], wid)) |idx| {
                            FrameLoop.handleEvent(&runtime.widgets, io, &queue, &windows[idx], per_window_slots[idx][0..per_window_slot_count[idx]], per_window_is_floating[idx][0..per_window_slot_count[idx]], per_window_topmost_modal[idx], event);
                        }
                    }
                },
            }
        }

        for (windows[0..window_count], 0..) |*wctx, i| {
            FrameLoop.drawWindow(&runtime.widgets, io, &queue, wctx, per_window_slots[i][0..per_window_slot_count[i]], per_window_is_floating[i][0..per_window_slot_count[i]], per_window_topmost_modal[i], arrow_cursor, pointer_cursor);
        }
    }

    std.debug.print("[main] window closed -- shutting down\n", .{});
    queue.requestShutdown(io);
    worker.join();

    // Tears down every still-open window's OS resources, replacing a single
    // set of `defer`s now that more than one window can exist. SDL_ttf
    // requires every TTF_Text be destroyed before the engine that made it --
    // destroyAllTextObjects doesn't care which engine created a given text
    // object (TTF_DestroyText itself takes no engine argument), so one
    // registry-wide call before tearing down every window's own engine
    // satisfies that ordering for all of them at once.
    runtime.widgets.destroyAllTextObjects(io);
    for (windows[0..window_count]) |*wctx| WindowManager.destroyWindowContext(wctx, allocator);

    std.debug.print("[main] clean shutdown\n", .{});
}
