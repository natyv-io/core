const std = @import("std");
const c = @import("c.zig").c;
const Config = @import("Config.zig");
const Manifest = @import("Manifest.zig");
const Runtime = @import("Runtime.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");
const ClayLayout = @import("capabilities/ClayLayout.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");
const DrawBatcher = @import("DrawBatcher.zig");

const max_widgets_on_screen = WidgetHost.max_widgets;

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

    // L4: `null` when ui.backend isn't "clay" -- no arena allocated, no
    // per-frame Clay calls at all, same "capability you didn't declare
    // costs you nothing" story as sqlite/network above.
    var maybe_clay_layout: ?ClayLayout = if (clay_enabled) try ClayLayout.init(allocator, 900, 700) else null;
    defer if (maybe_clay_layout) |*cl| cl.deinit(allocator);

    const arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    defer if (arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
    const pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    defer if (pointer_cursor) |cur| c.SDL_DestroyCursor(cur);
    var cursor_is_pointer = false;

    var focused_textfield: ?u32 = null;

    std.debug.print("[main] window open -- close it to quit.\n", .{});

    var running = true;
    var widget_snapshot: [max_widgets_on_screen]WidgetHost.Slot = undefined;
    var draw_batcher: DrawBatcher = .{};

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
            clay_layout.layoutIfNeeded(&runtime.widgets, io, @floatFromInt(win_w), @floatFromInt(win_h), mouse_x, mouse_y, (mouse_buttons & c.SDL_BUTTON_LMASK) != 0);
        }

        const widget_count = runtime.widgets.snapshot(io, &widget_snapshot);

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    if (event.button.button == c.SDL_BUTTON_LEFT) {
                        const mx = event.button.x;
                        const my = event.button.y;
                        var hit_field: ?u32 = null;

                        for (widget_snapshot[0..widget_count]) |slot| {
                            switch (slot.widget) {
                                .button => |b| if (b.containsPoint(mx, my)) {
                                    runtime.widgets.flashButton(io, slot.id);
                                    queue.push(io, slot.id, .click, "");
                                },
                                .textfield => |t| if (t.containsPoint(mx, my)) {
                                    hit_field = slot.id;
                                },
                                .label => {},
                                .container => {},
                            }
                        }
                        focused_textfield = hit_field;
                        runtime.widgets.setFocused(io, hit_field);
                        if (hit_field != null) {
                            _ = c.SDL_StartTextInput(window);
                        } else {
                            _ = c.SDL_StopTextInput(window);
                        }
                    }
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    if (focused_textfield) |id| runtime.widgets.appendTextTo(io, id, std.mem.span(event.text.text));
                },
                c.SDL_EVENT_KEY_DOWN => {
                    if (event.key.key == c.SDLK_BACKSPACE) {
                        if (focused_textfield) |id| runtime.widgets.backspaceOn(io, id);
                    }
                },
                else => {},
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
                .label => {},
                .container => {},
            }
        }
        if (hovering_any != cursor_is_pointer) {
            cursor_is_pointer = hovering_any;
            _ = c.SDL_SetCursor(if (hovering_any) pointer_cursor else arrow_cursor);
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 24, 24, 28, 255);
        _ = c.SDL_RenderClear(renderer);

        // L4.5: one SDL_RenderFillRects call per distinct fill color across
        // every widget, instead of each widget filling its own rect one at
        // a time -- see DrawBatcher.zig. `draw_batcher` is declared outside
        // the frame loop and reused every frame purely to avoid re-zeroing
        // its scratch arrays each time; `flush` below resets it for the
        // next frame regardless.
        for (widget_snapshot[0..widget_count]) |slot| {
            if (slot.widget.fillRect()) |fr| draw_batcher.add(fr.color, fr.rect);
        }
        draw_batcher.flush(renderer);

        for (widget_snapshot[0..widget_count]) |slot| {
            switch (slot.widget) {
                .button => |b| b.drawDecorations(renderer),
                .textfield => |t| t.drawDecorations(renderer),
                .label => |l| l.drawDecorations(renderer),
                // L2: containers are layout-only, nothing to draw -- see
                // Container.zig's doc comment.
                .container => {},
            }
        }

        _ = c.SDL_RenderPresent(renderer);
    }

    std.debug.print("[main] window closed -- shutting down\n", .{});
    queue.requestShutdown(io);
    worker.join();
    std.debug.print("[main] clean shutdown\n", .{});
}
