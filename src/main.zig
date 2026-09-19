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

/// How long the main loop's SDL_WaitEventTimeout blocks before waking on
/// its own even with no real OS event -- chosen to sit at/under one vsync
/// interval at the common 60Hz refresh rate (WindowManager's own
/// SDL_SetRenderVSync is the real frame-pacing mechanism once something
/// actually redraws; this timeout just bounds how long the loop can go
/// fully idle between checking things like hover thresholds or a Button's
/// own flash-timeout, without spinning to do so).
const frame_wait_timeout_ms: i32 = 16;

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

// Idle-CPU fix, part 2: `FrameLoop.rebuildFrameSnapshot`/`syncAllWindowText`
// do a full copy of the entire widget registry with no dirty-check of their
// own (unlike `ClayLayout.layoutIfNeeded`, which already has one) -- real,
// live-measured cost via `sample`, dominant once the rest of the loop was
// throttled. Safe to skip only when *nothing* could have changed since the
// snapshot was last rebuilt: `layout_generation` covers every registry
// mutation (widget create/destroy/style/focus/checked/value/... -- see
// WidgetHost.zig's own mutators, all audited to bump it on real change), but
// NOT `WidgetHost.setRect`/`setScrollData`, which a real Clay recompute
// (scroll or resize, not just content) writes back without ever bumping
// generation -- see `ClayLayout.layoutIfNeeded`'s own doc comment. So this
// also has to check `did_recompute` (set by `FrameLoop.layoutWindow`, called
// unconditionally just before this on both the pre-event and post-event
// paths) across every open window, not generation alone.
fn needsSnapshotRebuild(widgets: *WidgetHost, io: std.Io, windows: []const WindowManager.WindowContext, last_generation: ?u64) bool {
    if (last_generation == null or widgets.currentGeneration(io) != last_generation.?) return true;
    for (windows) |w| {
        if (w.did_recompute) return true;
    }
    return false;
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

    // A real, dedicated SDL event type Dispatch.run (the worker thread)
    // pushes after every natyv_dispatch call returns, so the main loop's
    // own SDL_WaitEventTimeout below wakes immediately on a worker-thread-
    // driven widget change instead of waiting out its own timeout or a real
    // OS event -- SDL_RegisterEvents/SDL_PushEvent are both documented safe
    // to call from any thread, confirmed against SDL3's own header. Done
    // once here, before the worker thread is spawned, and threaded through
    // rather than each side deriving it independently.
    const wake_event_type = c.SDL_RegisterEvents(1);

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

    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue, wake_event_type, config.value.memory.recycle_threshold_mb });

    // Multi-window: every open window's own real OS resources + per-window
    // frame state lives in this array -- `windows[0]` is always the original
    // startup window (`root_widget_id == null`), constructed the same way
    // every other window is (via `WindowManager.createWindowContext`) rather
    // than as a special case. Every window after it is opened/closed by a
    // guest's own `natyv_clay_create_window`/`natyv_destroy_window` calls,
    // drained from `WidgetHost`'s pending queues each frame below.
    // Heap-allocated (once, here, freed on return) for the same reason
    // `per_window_slots`/`widget_snapshot` below now are: `WindowContext`
    // itself grew large enough to blow the main thread's stack across 8
    // of them once `DrawBatcher.max_colors`'s own 2026-09-07 bump (8 -> 32,
    // see that constant's own doc comment) made its `rects` field
    // meaningfully bigger -- a second real, live-reproduced segfault from
    // the same root class (a big struct multiplied by max_open_windows,
    // stack-local), caught the same way.
    const windows = try allocator.alloc(WindowManager.WindowContext, WindowManager.max_open_windows);
    defer allocator.free(windows);
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
    // locals already set. Heap-allocated (once, here, freed on return) since
    // `max_widgets`'s 2026-09-07 bump (192 -> 2048, see that constant's own
    // doc comment): a `[8][2048]Slot` stack-local blew the main thread's
    // stack the moment this function was entered, a real, live-reproduced
    // segfault -- confirmed at exactly this bump, not present at 192. Still
    // exactly one allocation for this function's entire lifetime, not a
    // per-frame cost, so this doesn't reintroduce the per-frame allocation
    // this whole arc has otherwise avoided.
    const per_window_slots = try allocator.alloc([max_widgets_on_screen]WidgetHost.Slot, WindowManager.max_open_windows);
    defer allocator.free(per_window_slots);
    var per_window_slot_count: [WindowManager.max_open_windows]usize = [_]usize{0} ** WindowManager.max_open_windows;
    var per_window_is_floating: [WindowManager.max_open_windows][max_widgets_on_screen]bool = undefined;
    var per_window_topmost_modal: [WindowManager.max_open_windows]?u32 = [_]?u32{null} ** WindowManager.max_open_windows;

    // Registry-wide snapshot (as opposed to `per_window_slots` above, each
    // window's own subset of it) -- hoisted above the loop for the same
    // reason `per_window_slots` already is: `needsSnapshotRebuild` below can
    // skip recomputing it on a genuinely idle iteration, and a skipped
    // iteration must see the previous iteration's still-valid data, not
    // `undefined`. Heap-allocated for the same reason `per_window_slots`
    // just above now is.
    const widget_snapshot = try allocator.alloc(WidgetHost.Slot, max_widgets_on_screen);
    defer allocator.free(widget_snapshot);
    var widget_count: usize = 0;
    // The `layout_generation` this snapshot was last rebuilt against --
    // `null` until the first real rebuild. See `needsSnapshotRebuild`.
    var last_snapshot_generation: ?u64 = null;

    // Idle-CPU fix, part 3: whether *any* open window currently needs a
    // short-timeout wait to keep animating (a visible Spinner, a Button
    // still fading its click flash, or a window still inside its post-
    // creation warmup -- see WindowContext.needs_frequent_wake's own doc
    // comment), set by the end of each iteration's draw loop and consulted
    // at the *top* of the next one. `true` initially -- correct and safe
    // default for the very first iteration, before any window has drawn
    // even once to report its own real state. When this is `false`, the
    // wait below blocks indefinitely (`SDL_WaitEvent`, no timeout) instead
    // of waking on a fixed cadence just to re-check nothing changed --
    // real, live-measured idle CPU floor after the snapshot-rebuild-skip
    // fix was almost entirely this fixed-cadence wake itself (mouse/window-
    // position syscalls, an expired-widget scan, and the hover hit-test
    // loop, all cheap individually but paid ~60x/sec forever). A worker-
    // thread-driven mutation (Dispatch.run's SDL_PushEvent) or any real OS
    // event still wakes this immediately either way -- only the "wake on a
    // timer for no reason" cost goes away.
    var any_needs_frequent_wake = true;

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
                    removeWindow(windows, &window_count, idx);
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
        // renderer-specific (see FrameLoop.syncAllWindowText's own doc
        // comment), so this can't be one registry-wide call the way flush/
        // destroy-expired above are. Called again after this same frame's
        // events are processed, right before drawing -- see that function's
        // own doc comment for why. Bundled under the same
        // needsSnapshotRebuild gate as rebuildFrameSnapshot just below --
        // both do their own unconditional full-registry `widgets.snapshot`
        // copy with no internal dirty-check, the real cost this gate exists
        // to skip on a genuinely idle iteration (see needsSnapshotRebuild's
        // own doc comment).
        //
        // Each window's own widget subset for this frame -- computed once
        // here (reused by this frame's event dispatch below, and by the
        // `.window_close_requested` push inside that same loop), and again
        // fresh right before drawing -- see FrameLoop.rebuildFrameSnapshot's
        // own doc comment for why the draw pass needs its own, later call.
        // `widget_snapshot`/`widget_count` are hoisted above the loop
        // specifically so a skipped iteration correctly reuses the previous
        // one's still-valid data instead of stale-but-uninitialized memory.
        if (needsSnapshotRebuild(&runtime.widgets, io, windows[0..window_count], last_snapshot_generation)) {
            FrameLoop.syncAllWindowText(&runtime.widgets, io, windows[0..window_count], default_font.font, widget_snapshot);
            widget_count = FrameLoop.rebuildFrameSnapshot(&runtime.widgets, io, windows[0..window_count], widget_snapshot, per_window_slots[0..window_count], per_window_slot_count[0..window_count], per_window_is_floating[0..window_count], per_window_topmost_modal[0..window_count]);
            last_snapshot_generation = runtime.widgets.currentGeneration(io);
        }

        // Scroll-into-view / file picker -- both anchored to the original
        // startup window, see FrameLoop.drainGlobalPending's own doc
        // comment.
        FrameLoop.drainGlobalPending(&runtime.widgets, io, &queue, windows[0].window, widget_snapshot[0..widget_count]);

        // Tree view: a real `.scroll` push for each scroll container this
        // frame's layout pass reported, per window.
        for (windows[0..window_count]) |*wctx| {
            FrameLoop.pushScrollEvents(&queue, io, wctx, widget_snapshot[0..widget_count]);
        }

        // Blocks (up to frame_wait_timeout_ms, or indefinitely -- see
        // any_needs_frequent_wake's own doc comment) instead of spinning
        // when there's nothing to do -- this, plus WindowManager's own
        // SDL_SetRenderVSync, is what actually bounds this loop's iteration
        // rate; see FrameLoop.zig's own dirty-check for the *drawing* half
        // of the fix. The first wait can return a real event or time out
        // with nothing (or, in indefinite mode, always returns with a real
        // event); either way, drain any further already-queued events via
        // plain non-blocking SDL_PollEvent so a burst doesn't each pay a
        // separate wait.
        var event: c.SDL_Event = undefined;
        var have_event = if (any_needs_frequent_wake)
            c.SDL_WaitEventTimeout(&event, frame_wait_timeout_ms)
        else
            c.SDL_WaitEvent(&event);
        // A bare timeout (no real event within frame_wait_timeout_ms) means
        // nothing happened this iteration at all -- the second layout/text-
        // sync/snapshot pass below exists only to reflect *this iteration's
        // own events* before drawing (see that block's own doc comment), so
        // skip it entirely rather than redoing the exact same recompute the
        // first pass above already did this same iteration. Without this,
        // a real idle-CPU regression: that second pass ran unconditionally
        // on every 16ms wake regardless of whether anything happened,
        // roughly doubling the loop's fixed per-iteration cost forever --
        // found via the mail-natyv benchmark re-run after this second pass
        // first landed (idle CPU ~8-16% -> ~41%, never re-measured when
        // that fix was added since only interactive correctness was
        // re-tested at the time).
        const had_real_event = have_event;
        while (have_event) {
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
            have_event = c.SDL_PollEvent(&event);
        }

        // Real, live-confirmed fix: recompute layout, re-sync text objects,
        // and refresh the widget snapshot fresh, right before drawing, so
        // this frame's own just-processed events (a keystroke's
        // `appendTextTo`, a Refresh click's whole new batch of
        // natyv_create_* calls, ...) are what actually gets drawn -- see
        // FrameLoop.layoutWindow/syncAllWindowText/rebuildFrameSnapshot's
        // own doc comments for the full story (the bug this fixes: input
        // otherwise looked delayed by exactly one event, invisible under
        // the old unthrottled loop but real once SDL_WaitEventTimeout
        // bounds this loop to real event/wake cadence). Layout must run
        // first -- newly-created widgets (e.g. a Refresh click's freshly
        // built message rows) have no real on-screen rect at all until a
        // real Clay layout pass writes one back; without this, the
        // registry-wide mutation was correctly reflected in the redrawn
        // widget *data*, but with stale (or no) positions, so some/all new
        // rows didn't visibly render until some *later*, unrelated event
        // (e.g. a page-nav click) forced another real layoutWindow call.
        // Reuses this same iteration's already-captured mouse position --
        // it can't have changed meaningfully within one loop iteration, and
        // `layoutWindow`'s own pending-scroll-delta consumption is already
        // safely zeroed from the earlier call this same iteration.
        if (had_real_event) {
            for (windows[0..window_count]) |*wctx| {
                FrameLoop.layoutWindow(&runtime.widgets, io, wctx, global_mouse_x, global_mouse_y, global_buttons);
            }
            // Same needsSnapshotRebuild gate as the pre-event pass above --
            // a real event doesn't always mean something snapshot-relevant
            // actually changed (e.g. a plain hover-only mouse move).
            if (needsSnapshotRebuild(&runtime.widgets, io, windows[0..window_count], last_snapshot_generation)) {
                FrameLoop.syncAllWindowText(&runtime.widgets, io, windows[0..window_count], default_font.font, widget_snapshot);
                widget_count = FrameLoop.rebuildFrameSnapshot(&runtime.widgets, io, windows[0..window_count], widget_snapshot, per_window_slots[0..window_count], per_window_slot_count[0..window_count], per_window_is_floating[0..window_count], per_window_topmost_modal[0..window_count]);
                last_snapshot_generation = runtime.widgets.currentGeneration(io);
            }
        }

        for (windows[0..window_count], 0..) |*wctx, i| {
            FrameLoop.drawWindow(&runtime.widgets, io, &queue, wctx, per_window_slots[i][0..per_window_slot_count[i]], per_window_is_floating[i][0..per_window_slot_count[i]], per_window_topmost_modal[i], arrow_cursor, pointer_cursor, default_font.font);
        }

        // Recompute for the *next* iteration's wait mode -- see
        // any_needs_frequent_wake's own doc comment. Every window's
        // `needs_frequent_wake` was just set fresh by the drawWindow calls
        // above (unconditionally, regardless of whether each one actually
        // redrew), so this always reflects this iteration's real state.
        // Also forced true by any pending widget expiry (see
        // WidgetHost.hasPendingExpiry's own doc comment) -- a toast-style
        // auto-dismissing widget needs the loop to keep checking on a timer
        // even with nothing else happening, or it would never get cleaned
        // up under an indefinite wait.
        any_needs_frequent_wake = runtime.widgets.hasPendingExpiry(io);
        for (windows[0..window_count]) |w| {
            if (w.needs_frequent_wake) any_needs_frequent_wake = true;
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
