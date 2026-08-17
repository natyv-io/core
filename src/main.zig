const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("Config.zig");
const Manifest = @import("Manifest.zig");
const Runtime = @import("Runtime.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");
const Slider = @import("widgets/Slider.zig");
const ClayLayout = @import("capabilities/ClayLayout.zig");
const Font = @import("capabilities/Font.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");
const DrawBatcher = @import("DrawBatcher.zig");
const ScrollClip = @import("ScrollClip.zig");
const ScrollBar = @import("ScrollBar.zig");

const max_widgets_on_screen = WidgetHost.max_widgets;

/// Keyboard interaction model: the one place focus actually changes (mouse
/// click, Tab/Shift+Tab, Escape all route through this) -- updates the
/// registry, the caller's local tracking var, and starts/stops
/// `SDL_StartTextInput` based on whether the newly focused widget is a
/// `TextField` (focusing a `Button` shouldn't turn on IME/text
/// composition). Kept as a free function taking everything explicitly
/// rather than a closure, since Zig's nested functions can't capture outer
/// locals.
fn updateFocus(widgets: *WidgetHost, io: std.Io, window: *c.SDL_Window, focused_widget_id: *?u32, new_id: ?u32) void {
    const is_textfield = widgets.setFocused(io, new_id);
    focused_widget_id.* = new_id;
    if (is_textfield) {
        _ = c.SDL_StartTextInput(window);
    } else {
        _ = c.SDL_StopTextInput(window);
    }
}

/// W2: `SDL_SetRenderClipRect` takes an integer `SDL_Rect`, not the
/// `SDL_FRect` every widget rect and DrawBatcher entry uses -- floor the
/// origin and ceil the extent (rather than a bare truncating cast) so a
/// partially-visible edge pixel is kept rather than clipped away early.
fn toClipRect(r: c.SDL_FRect) c.SDL_Rect {
    return .{
        .x = @intFromFloat(@floor(r.x)),
        .y = @intFromFloat(@floor(r.y)),
        .w = @intFromFloat(@ceil(r.w)),
        .h = @intFromFloat(@ceil(r.h)),
    };
}

/// W1: the shared "activate this widget" body for both a mouse click and a
/// keyboard Enter/Space -- one place so the two input paths can't drift
/// apart on what "activating" a given kind actually does. Not every kind is
/// activatable (TextField, Label, Container, ProgressBar aren't); those
/// just fall through without pushing an event at all, same as clicking
/// empty space today. W3: Slider joins that non-activatable set too --
/// Enter/Space isn't slider semantics, it's driven by drag/arrow-keys
/// instead (see `notifySliderValue` and the drag-update block below).
fn activateWidget(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, kind: WidgetHost.WidgetKind) void {
    switch (kind) {
        .button => widgets.flashButton(io, id),
        .checkbox => widgets.toggleCheckbox(io, id),
        .radio_button => widgets.selectRadioExclusive(io, id),
        .textfield, .label, .container, .progress_bar, .slider => return,
    }
    queue.push(io, id, .click, "");
}

/// W3: the slider counterpart to `activateWidget` -- called both from a
/// click-to-jump/drag update and an arrow-key nudge. Mutates the host-side
/// value immediately via `WidgetHost.setSliderValue` (so the thumb responds
/// the same frame, not waiting on a guest round trip) and, only if the
/// clamped value actually changed, pushes a "change" event carrying that
/// *clamped* value so the guest finds out too. `EventQueue.push`'s
/// `.change` coalescing means calling this every frame during a drag never
/// floods the queue -- only the latest value per widget is ever pending
/// delivery.
fn notifySliderValue(widgets: *WidgetHost, io: std.Io, queue: *EventQueue, id: u32, value: f32) void {
    const clamped = widgets.setSliderValue(io, id, value) orelse return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"value\":{d}}}", .{clamped}) catch "{}";
    queue.push(io, id, .change, json);
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
        .label = config.value.widgets.label,
        .checkbox = config.value.widgets.checkbox,
        .radio_button = config.value.widgets.radio_button,
        .progress_bar = config.value.widgets.progress_bar,
        .slider = config.value.widgets.slider,
    };
    const clay_enabled = if (config.value.ui.backend) |backend| std.mem.eql(u8, backend, "clay") else false;
    try runtime.loadPlugin(wasm, manifest, widget_kinds, clay_enabled);
    runtime.initGuest(io);

    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue });

    const window = c.SDL_CreateWindow(app_name_z.ptr, 900, 700, 0) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlRendererFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    // F3: one renderer-backed text engine for the app's lifetime -- every
    // widget's cached TTF_Text is created against this. SDL_ttf requires
    // every TTF_Text be destroyed before the engine that made it, so
    // `destroyAllTextObjects`'s defer is declared *after* this one --
    // Zig's LIFO defer order means it runs first at shutdown, same
    // ordering fix Clay's global-context clearing needed in L4.
    const text_engine = c.TTF_CreateRendererTextEngine(renderer) orelse {
        std.debug.print("TTF_CreateRendererTextEngine failed: {s}\n", .{c.SDL_GetError()});
        return error.TextEngineFailed;
    };
    defer c.TTF_DestroyRendererTextEngine(text_engine);
    defer runtime.widgets.destroyAllTextObjects(io);

    // L4: `null` when ui.backend isn't "clay" -- no arena allocated, no
    // per-frame Clay calls at all, same "capability you didn't declare
    // costs you nothing" story as sqlite/network above.
    var maybe_clay_layout: ?ClayLayout = if (clay_enabled) try ClayLayout.init(allocator, 900, 700, default_font.font) else null;
    defer if (maybe_clay_layout) |*cl| cl.deinit(allocator);

    const arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    defer if (arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
    const pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    defer if (pointer_cursor) |cur| c.SDL_DestroyCursor(cur);
    var cursor_is_pointer = false;

    var focused_widget_id: ?u32 = null;
    // W3: which slider (if any) is currently being dragged -- set on
    // MOUSE_BUTTON_DOWN when the click lands on a slider, cleared
    // unconditionally on MOUSE_BUTTON_UP regardless of where the mouse
    // currently is (standard drag semantics: releasing outside the widget's
    // bounds still ends the drag). Not stored on the widget itself, same
    // "main.zig owns interaction state, WidgetHost owns widget state"
    // split `focused_widget_id` already establishes.
    var dragging_slider_id: ?u32 = null;

    std.debug.print("[main] window open -- close it to quit.\n", .{});

    var running = true;
    var widget_snapshot: [max_widgets_on_screen]WidgetHost.Slot = undefined;
    var clip_rects: [max_widgets_on_screen]?c.SDL_FRect = undefined;
    var draw_batcher: DrawBatcher = .{};

    // W2: accumulated per-frame wheel delta, in pixels (already scaled from
    // SDL's raw wheel "notch" units), consumed by layoutIfNeeded at the top
    // of the *next* frame then reset -- the poll loop that discovers wheel
    // events runs after layoutIfNeeded's call site (see the ordering note
    // below), so this is a deliberate one-frame lag, same idea as
    // EventQueue's own "drain once per frame" discrete-event handling
    // elsewhere in this codebase.
    var pending_scroll_dx: f32 = 0;
    var pending_scroll_dy: f32 = 0;
    // Pixels of scroll per SDL wheel "notch" (event.wheel.x/y), before
    // Clay's own internal *10 multiplier on top of that (see
    // Clay_UpdateScrollContainers) -- tuned so one notch moves roughly one
    // bookstore row (~38px), not a token amount.
    const wheel_pixels_per_notch: f32 = 4.0;

    while (running) {
        var mouse_x: f32 = undefined;
        var mouse_y: f32 = undefined;
        const mouse_buttons = c.SDL_GetMouseState(&mouse_x, &mouse_y);

        // Must run before this frame's snapshot below, not after -- so
        // that if a real Clay recompute happens this frame, the freshly
        // written-back `rect`s are what the rest of the frame (hit-testing,
        // hover, drawing) actually sees, not last frame's stale ones.
        if (maybe_clay_layout) |*clay_layout| {
            var win_w: c_int = undefined;
            var win_h: c_int = undefined;
            _ = c.SDL_GetWindowSize(window, &win_w, &win_h);
            clay_layout.layoutIfNeeded(&runtime.widgets, io, @floatFromInt(win_w), @floatFromInt(win_h), mouse_x, mouse_y, (mouse_buttons & c.SDL_BUTTON_LMASK) != 0, pending_scroll_dx, pending_scroll_dy);
        }
        pending_scroll_dx = 0;
        pending_scroll_dy = 0;

        // F3: a guest destroying a widget (natyv_destroy_widget, called on
        // the worker thread inside natyv_dispatch) can't destroy its
        // TTF_Text right then -- that's only valid on the thread that
        // created it. It queues the pointer instead; this is the main
        // thread actually freeing it, once per frame. Must run before
        // syncTextObjects below in case a widget was destroyed and a new
        // one with the same generation-counter state gets created in its
        // place within the same guest call.
        runtime.widgets.flushPendingTextDestroys(io);

        // F3: same "mutate the live registry, then snapshot sees the fresh
        // result" ordering as layoutIfNeeded above -- must run before
        // snapshot so a widget created or re-labeled this frame already has
        // a real (or updated) TTF_Text by the time drawDecorations reads it.
        runtime.widgets.syncTextObjects(io, text_engine, default_font.font);

        const widget_count = runtime.widgets.snapshot(io, &widget_snapshot);

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        const mx = event.button.x;
                        const my = event.button.y;
                        // Keyboard interaction model: a click now focuses
                        // whatever it hits (button or textfield, not just
                        // textfield as before) so Tab-navigation picks up
                        // naturally from wherever the mouse last landed.
                        // Buttons still fire immediately on click, same as
                        // before -- focusing them is additional, not a
                        // replacement for that.
                        var hit_focusable: ?u32 = null;

                        for (widget_snapshot[0..widget_count]) |slot| {
                            switch (slot.widget) {
                                .button => |b| if (b.containsPoint(mx, my)) {
                                    activateWidget(&runtime.widgets, io, &queue, slot.id, .button);
                                    hit_focusable = slot.id;
                                },
                                .checkbox => |cb| if (cb.containsPoint(mx, my)) {
                                    activateWidget(&runtime.widgets, io, &queue, slot.id, .checkbox);
                                    hit_focusable = slot.id;
                                },
                                .radio_button => |r| if (r.containsPoint(mx, my)) {
                                    activateWidget(&runtime.widgets, io, &queue, slot.id, .radio_button);
                                    hit_focusable = slot.id;
                                },
                                .textfield => |t| if (t.containsPoint(mx, my)) {
                                    hit_focusable = slot.id;
                                },
                                // W3: just starts the drag -- no value is
                                // computed here. The per-frame drag-update
                                // block below runs later this same frame
                                // (using the polled mouse_x, essentially
                                // identical to `mx`/`my` here) and handles
                                // both this click-to-jump case and every
                                // subsequent drag frame through one code
                                // path, not two.
                                .slider => |s| if (s.containsPoint(mx, my)) {
                                    hit_focusable = slot.id;
                                    dragging_slider_id = slot.id;
                                },
                                .label => {},
                                .container => {},
                                .progress_bar => {},
                            }
                        }
                        updateFocus(&runtime.widgets, io, window, &focused_widget_id, hit_focusable);
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    // W3: ends the drag unconditionally, regardless of
                    // where the mouse currently is -- standard drag
                    // semantics (releasing outside the widget's bounds
                    // still stops it).
                    if (event.button.button == c.SDL_BUTTON_LEFT) dragging_slider_id = null;
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    if (focused_widget_id) |id| runtime.widgets.appendTextTo(io, id, std.mem.span(event.text.text));
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    // Not negated: confirmed against real hardware (Quinn's
                    // click-through) that Clay's scrollPosition should move
                    // directly with SDL's raw wheel.x/y sign, not inverted.
                    // The original negation was based on a scroll-convention
                    // assumption that turned out backwards in practice.
                    pending_scroll_dx += event.wheel.x * wheel_pixels_per_notch;
                    pending_scroll_dy += event.wheel.y * wheel_pixels_per_notch;
                },
                c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                    c.SDLK_BACKSPACE => if (focused_widget_id) |id| runtime.widgets.backspaceOn(io, id),
                    c.SDLK_TAB => {
                        var focusable_ids: [max_widgets_on_screen]u32 = undefined;
                        const focusable_count = runtime.widgets.focusableIdsSorted(io, &focusable_ids);
                        const forward = (event.key.mod & c.SDL_KMOD_SHIFT) == 0;
                        const next = WidgetHost.nextFocusable(focusable_ids[0..focusable_count], focused_widget_id, forward);
                        updateFocus(&runtime.widgets, io, window, &focused_widget_id, next);
                    },
                    c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_SPACE => {
                        // Activates a focused Button/Checkbox/RadioButton --
                        // a focused TextField never reaches here for Space,
                        // since that's delivered as literal text via
                        // SDL_EVENT_TEXT_INPUT instead, not this key-down
                        // path. `activateWidget` itself no-ops for any kind
                        // that isn't activatable.
                        if (focused_widget_id) |id| {
                            for (widget_snapshot[0..widget_count]) |slot| {
                                if (slot.id == id) {
                                    activateWidget(&runtime.widgets, io, &queue, id, std.meta.activeTag(slot.widget));
                                }
                            }
                        }
                    },
                    c.SDLK_ESCAPE => updateFocus(&runtime.widgets, io, window, &focused_widget_id, null),
                    // W3: nudges the *focused* widget's value if it's a
                    // slider -- confirmed unbound by anything else in this
                    // switch today, so safe to add unconditionally; a no-op
                    // when nothing focused or the focused widget isn't a
                    // slider (`notifySliderValue`/`setSliderValue` both
                    // handle that, see their doc comments).
                    c.SDLK_LEFT, c.SDLK_DOWN => if (focused_widget_id) |id| {
                        for (widget_snapshot[0..widget_count]) |slot| {
                            if (slot.id == id and slot.widget == .slider) {
                                notifySliderValue(&runtime.widgets, io, &queue, id, slot.widget.slider.value - Slider.nudge_step);
                            }
                        }
                    },
                    c.SDLK_RIGHT, c.SDLK_UP => if (focused_widget_id) |id| {
                        for (widget_snapshot[0..widget_count]) |slot| {
                            if (slot.id == id and slot.widget == .slider) {
                                notifySliderValue(&runtime.widgets, io, &queue, id, slot.widget.slider.value + Slider.nudge_step);
                            }
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }

        // W3: per-frame slider drag update -- runs after the event-poll
        // loop above (so `dragging_slider_id` set earlier this same frame,
        // on the initial click, is already visible here), using the
        // already-polled `mouse_x`/`mouse_y` from the top of the loop
        // rather than a dedicated MOUSE_MOTION handler. This one block
        // covers both "jump to click position" and "continue following the
        // drag" -- no separate code path needed for the click-to-jump case.
        if (dragging_slider_id) |id| {
            for (widget_snapshot[0..widget_count]) |slot| {
                if (slot.id == id and slot.widget == .slider) {
                    notifySliderValue(&runtime.widgets, io, &queue, id, slot.widget.slider.valueFromX(mouse_x));
                }
            }
        }

        var hovering_any = false;
        for (widget_snapshot[0..widget_count]) |slot| {
            switch (slot.widget) {
                .button => |b| if (b.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                },
                .textfield => |t| if (t.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                },
                .checkbox => |cb| if (cb.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                },
                .radio_button => |r| if (r.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                },
                .slider => |s| if (s.containsPoint(mouse_x, mouse_y)) {
                    hovering_any = true;
                },
                .label => {},
                .container => {},
                .progress_bar => {},
            }
        }
        if (hovering_any != cursor_is_pointer) {
            cursor_is_pointer = hovering_any;
            _ = c.SDL_SetCursor(if (hovering_any) pointer_cursor else arrow_cursor);
        }

        // W2: computed once per frame -- for each widget, the rect it must
        // be visually clipped to (the intersection of every scroll-clipping
        // ancestor's rect up its parent chain), or null if none applies.
        // Clay already computed correct *positions* for a scroll
        // container's children via childOffset; this is the separate,
        // natyv-owned step of actually cropping their rendering, since Clay
        // has no opinion on how (or whether) natyv draws anything.
        ScrollClip.computeClipRects(widget_snapshot[0..widget_count], clip_rects[0..widget_count]);

        _ = c.SDL_SetRenderDrawColor(renderer, 24, 24, 28, 255);
        _ = c.SDL_RenderClear(renderer);

        // L4.5/W2: one SDL_RenderFillRects call per distinct fill color
        // across every *unclipped* widget -- see DrawBatcher.zig.
        // `draw_batcher` is declared outside the frame loop and reused
        // every frame purely to avoid re-zeroing its scratch arrays each
        // time; `flush` below resets it for the next frame regardless. A
        // widget with a non-null clip rect bypasses the batcher entirely
        // and is filled individually inside its own
        // SDL_SetRenderClipRect/null bracket -- DrawBatcher only ever
        // issues one draw color per call, so it can't represent "these N
        // rects share a color but need M different active clip rects."
        // Deliberately not extending the batcher for this: scroll-clipped
        // widgets are a minority of on-screen widgets in any real app (see
        // DrawBatcher.zig's own "tens, not thousands" framing), so a
        // less-batched path for just those is a reasonable trade over a
        // more complex (color, clip_rect) bucket key.
        for (widget_snapshot[0..widget_count], clip_rects[0..widget_count]) |slot, clip| {
            if (slot.widget.fillRect()) |fr| {
                if (clip) |cr| {
                    const sdl_clip = toClipRect(cr);
                    _ = c.SDL_SetRenderClipRect(renderer, &sdl_clip);
                    _ = c.SDL_SetRenderDrawColor(renderer, fr.color.r, fr.color.g, fr.color.b, fr.color.a);
                    _ = c.SDL_RenderFillRect(renderer, &fr.rect);
                    _ = c.SDL_SetRenderClipRect(renderer, null);
                } else {
                    draw_batcher.add(fr.color, fr.rect);
                }
            }
        }
        draw_batcher.flush(renderer);

        for (widget_snapshot[0..widget_count], clip_rects[0..widget_count]) |slot, clip| {
            const sdl_clip: c.SDL_Rect = if (clip) |cr| toClipRect(cr) else undefined;
            if (clip != null) _ = c.SDL_SetRenderClipRect(renderer, &sdl_clip);
            switch (slot.widget) {
                .button => |b| b.drawDecorations(renderer),
                .textfield => |t| t.drawDecorations(renderer),
                .label => |l| l.drawDecorations(renderer),
                .checkbox => |cb| cb.drawDecorations(renderer),
                .radio_button => |r| r.drawDecorations(renderer),
                .progress_bar => |p| p.drawDecorations(renderer),
                .slider => |s| s.drawDecorations(renderer),
                // L2: containers are layout-only, nothing to draw -- see
                // Container.zig's doc comment.
                .container => {},
            }
            if (clip != null) _ = c.SDL_SetRenderClipRect(renderer, null);
        }

        // W2: scrollbar thumbs -- display-only position indicators (not
        // draggable, see ScrollBar.zig's doc comment) drawn last, on top of
        // everything else, one per scroll axis a Clay-managed container
        // declared. Drawn unclipped -- ScrollBar.zig insets the thumb inside
        // its own container's rect already, so it never needs cropping
        // against an ancestor's clip rect the way scrolled *content* does.
        if (maybe_clay_layout != null) {
            for (widget_snapshot[0..widget_count]) |slot| {
                if (!slot.clay_managed or slot.widget != .container) continue;
                if (!(slot.clay_style.scroll_vertical or slot.clay_style.scroll_horizontal)) continue;
                const data = ClayLayout.scrollContainerData(slot.id) orelse continue;
                const container_rect = slot.widget.container.rect;

                _ = c.SDL_SetRenderDrawColor(renderer, 150, 150, 160, 190);
                if (slot.clay_style.scroll_vertical) {
                    if (ScrollBar.verticalThumb(container_rect, data)) |thumb| {
                        _ = c.SDL_RenderFillRect(renderer, &thumb);
                    }
                }
                if (slot.clay_style.scroll_horizontal) {
                    if (ScrollBar.horizontalThumb(container_rect, data)) |thumb| {
                        _ = c.SDL_RenderFillRect(renderer, &thumb);
                    }
                }
            }
        }

        _ = c.SDL_RenderPresent(renderer);
    }

    std.debug.print("[main] window closed -- shutting down\n", .{});
    queue.requestShutdown(io);
    worker.join();
    std.debug.print("[main] clean shutdown\n", .{});
}
