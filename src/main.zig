const std = @import("std");
const c = @import("c.zig").c;
const Runtime = @import("Runtime.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");
const EventQueue = @import("EventQueue.zig");
const Dispatch = @import("Dispatch.zig");

const max_widgets_on_screen = WidgetHost.max_widgets;
const max_allowed_hosts = 8;

// M5: this file has zero app-specific knowledge -- no schema, no widget
// layout, no network-host allowlist baked in for a particular app. Every
// rect on screen exists because the guest called
// natyv_create_button/natyv_create_textfield/natyv_create_label during
// natyv_init or a later natyv_dispatch; every click becomes a queued event
// a worker thread turns into a natyv_dispatch call.
//
// `allowed_hosts` is the one thing that can NOT move into the guest --
// letting a guest declare its own network permissions would defeat the
// point of a host-enforced security boundary -- so it's a launch-time host
// argument instead. A real natyv install would read this (and the app path)
// from a per-app manifest/config file rather than argv; that file format
// isn't designed yet (see project's "open design threads"), so argv is the
// placeholder until then.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const argv = init.minimal.args.vector;
    const app_wasm_path: []const u8 = if (argv.len > 1) std.mem.span(argv[1]) else "examples/counter/guest/counter.wasm";

    var allowed_hosts_buf: [max_allowed_hosts][]const u8 = undefined;
    var allowed_hosts: ?[]const []const u8 = null;
    if (argv.len > 2) {
        var it = std.mem.splitScalar(u8, std.mem.span(argv[2]), ',');
        var n: usize = 0;
        while (it.next()) |host| : (n += 1) {
            if (n >= max_allowed_hosts) break;
            allowed_hosts_buf[n] = host;
        }
        allowed_hosts = allowed_hosts_buf[0..n];
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    const pref_path_c = c.SDL_GetPrefPath("natyv", "host") orelse {
        std.debug.print("SDL_GetPrefPath failed: {s}\n", .{c.SDL_GetError()});
        return error.PrefPathFailed;
    };
    defer c.SDL_free(pref_path_c);
    const pref_path = std.mem.span(pref_path_c);

    var db_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = std.fmt.bufPrintZ(&db_path_buf, "{s}data.sqlite3", .{pref_path}) catch {
        std.debug.print("[main] db path too long\n", .{});
        return error.PathTooLong;
    };

    std.debug.print("[main] app: {s}\n[main] database: {s}\n", .{ app_wasm_path, db_path });

    const wasm = std.Io.Dir.cwd().readFileAlloc(io, app_wasm_path, allocator, .unlimited) catch |err| {
        std.debug.print("[main] failed to read {s}: {}\n", .{ app_wasm_path, err });
        return err;
    };
    defer allocator.free(wasm);

    var runtime = try Runtime.init(allocator, db_path);
    defer runtime.deinit();

    try runtime.loadPlugin(wasm, .{ .allowed_hosts = allowed_hosts });
    runtime.initGuest(io);

    var queue = EventQueue.init(allocator);
    defer queue.deinit();

    const worker = try std.Thread.spawn(.{}, Dispatch.run, .{ &runtime, io, &queue });

    const window = c.SDL_CreateWindow("natyv", 900, 700, 0) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlRendererFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    const arrow_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT);
    defer if (arrow_cursor) |cur| c.SDL_DestroyCursor(cur);
    const pointer_cursor = c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER);
    defer if (pointer_cursor) |cur| c.SDL_DestroyCursor(cur);
    var cursor_is_pointer = false;

    var focused_textfield: ?u32 = null;

    std.debug.print("[main] window open -- close it to quit.\n", .{});

    var running = true;
    var widget_snapshot: [max_widgets_on_screen]WidgetHost.Slot = undefined;

    while (running) {
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

        var mouse_x: f32 = undefined;
        var mouse_y: f32 = undefined;
        _ = c.SDL_GetMouseState(&mouse_x, &mouse_y);
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
            }
        }
        if (hovering_any != cursor_is_pointer) {
            cursor_is_pointer = hovering_any;
            _ = c.SDL_SetCursor(if (hovering_any) pointer_cursor else arrow_cursor);
        }

        _ = c.SDL_SetRenderDrawColor(renderer, 24, 24, 28, 255);
        _ = c.SDL_RenderClear(renderer);

        for (widget_snapshot[0..widget_count]) |slot| {
            switch (slot.widget) {
                .button => |b| b.draw(renderer),
                .textfield => |t| t.draw(renderer),
                .label => |l| l.draw(renderer),
            }
        }

        _ = c.SDL_RenderPresent(renderer);
    }

    std.debug.print("[main] window closed -- shutting down\n", .{});
    queue.requestShutdown(io);
    worker.join();
    std.debug.print("[main] clean shutdown\n", .{});
}
