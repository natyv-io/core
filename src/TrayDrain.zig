//! The main-thread half of the system tray: turns `TrayRegistry`'s queued
//! operations into real `SDL_Tray*` calls, and turns SDL's own entry
//! callbacks back into `EventQueue` events.
//!
//! Split out of `FrameLoop.zig` rather than added to it: that file is
//! already 1400+ lines and this is a genuine seam, not a few more lines of
//! the same work -- it owns every `SDL_Tray*` call in the codebase and
//! nothing else does.
//!
//! **Why this runs on the main thread.** Every `SDL_Tray*` function is
//! documented main-thread-only, or "on the thread that created the tray",
//! while every `natyv_tray_*` host function runs on the dispatch worker.
//! `TrayRegistry` absorbs that split; this file is the only place the
//! crossing is actually resolved. See that file's header.
//!
//! **Why nothing here needs an explicit `SDL_UpdateTrays`.** SDL's own doc:
//! "This is called automatically by the event loop and is only needed if
//! you're using trays but aren't handling SDL events." `main.zig` pumps
//! events every frame, so the tray updates itself and entry callbacks
//! arrive during that pump -- on the main thread, which is what makes
//! reading `SDL_GetTrayEntryChecked` inside the callback legal.

const std = @import("std");
const Io = std.Io;
const c = @import("c.zig").c;
const EventQueue = @import("EventQueue.zig");
const TrayRegistry = @import("TrayRegistry.zig");
const TrayIcon = @import("TrayIcon");

/// Everything a tray callback needs that is not per-entry. Set once by
/// `init` and read by every callback afterwards -- same "address stable for
/// main()'s whole lifetime" shape `FrameLoop.file_dialog_ctx` already uses,
/// just shared across entries instead of one per dialog, since the
/// per-entry half already lives in each `Entry`'s own `CallbackContext`.
const CallbackEnv = struct {
    io: Io,
    queue: *EventQueue,
};

var callback_env: ?CallbackEnv = null;

/// The decoded icon surface, created once on first use and kept alive for
/// the process's lifetime. `SDL_CreateTray`/`SDL_SetTrayIcon` are not
/// documented to copy the surface, and the cost of holding one small
/// decoded PNG is not worth the risk of finding out they do not.
var icon_surface: ?*c.SDL_Surface = null;
var icon_pixels: ?[*]u8 = null;
var icon_tried: bool = false;

/// Call once, before the first `drain`. Separate from `drain` so the
/// environment is in place even for a callback that somehow fires before
/// the first op is queued.
pub fn init(io: Io, queue: *EventQueue) void {
    callback_env = .{ .io = io, .queue = queue };
}

/// Frees the decoded icon. Trays themselves are destroyed through their own
/// `.destroy_tray` ops, or left to process exit -- SDL tears its own tray
/// resources down at `SDL_Quit`.
pub fn deinit() void {
    if (icon_surface) |s| {
        c.SDL_DestroySurface(s);
        icon_surface = null;
    }
    if (icon_pixels) |p| {
        c.stbi_image_free(p);
        icon_pixels = null;
    }
    icon_tried = false;
}

/// Decodes `conf.natyv.json`'s staged icon PNG into an SDL surface, once.
/// Returns null when no icon was configured (the `TrayIconAbsent.zig` stub)
/// or the bytes failed to decode -- both of which `SDL_CreateTray` accepts,
/// since its `icon` parameter is documented "May be NULL".
///
/// Decoding goes through stb_image on already-`@embedFile`'d bytes, exactly
/// like `capabilities/ImageCache.zig` -- natyv never reads an image from a
/// filesystem path at runtime. Forcing 4 channels gives RGBA regardless of
/// what the source PNG actually carried, which is what
/// `SDL_PIXELFORMAT_RGBA32` below then expects.
fn iconSurface() ?*c.SDL_Surface {
    if (icon_tried) return icon_surface;
    icon_tried = true;

    const bytes = TrayIcon.data orelse return null;

    var w: c_int = 0;
    var h: c_int = 0;
    var channels_in_file: c_int = 0;
    const pixels = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &channels_in_file, 4) orelse {
        std.debug.print("[tray] could not decode the configured icon; continuing without one\n", .{});
        return null;
    };

    // stb_image always emits tightly-packed rows when asked for 4 channels,
    // so the pitch is exactly w * 4 -- same assumption ImageCache makes.
    const surface = c.SDL_CreateSurfaceFrom(w, h, c.SDL_PIXELFORMAT_RGBA32, pixels, w * 4) orelse {
        c.stbi_image_free(pixels);
        std.debug.print("[tray] SDL_CreateSurfaceFrom failed: {s}\n", .{c.SDL_GetError()});
        return null;
    };

    // The surface borrows these pixels rather than copying them, so both
    // have to outlive every tray that uses them -- hence the module-level
    // storage and the paired free in `deinit`.
    icon_pixels = pixels;
    icon_surface = surface;
    return surface;
}

/// Applies every operation queued since the last call. Cheap and a no-op in
/// the overwhelmingly common case (an app that creates its tray once during
/// `natyv_init` queues nothing on any subsequent frame).
pub fn drain(registry: *TrayRegistry, io: Io) void {
    var ops: [TrayRegistry.max_pending_ops]TrayRegistry.Op = undefined;
    const n = registry.takeOps(io, &ops);
    for (ops[0..n]) |op| apply(registry, io, op);
}

fn apply(registry: *TrayRegistry, io: Io, op: TrayRegistry.Op) void {
    switch (op) {
        .create_tray => |req| {
            var scratch: [TrayRegistry.max_tooltip_len + 1]u8 = undefined;
            var tip = req.tooltip;
            const tooltip_z = tip.cString(&scratch);
            const tray = c.SDL_CreateTray(iconSurface(), if (tooltip_z.len == 0) null else tooltip_z.ptr) orelse {
                std.debug.print("[tray] SDL_CreateTray failed: {s}\n", .{c.SDL_GetError()});
                registry.forgetTray(io, req.id);
                return;
            };
            // A tray with no menu can hold no entries and natyv exposes no
            // way to use one, so the two are always created together --
            // see `TrayRegistry.Tray.menu`.
            const menu = c.SDL_CreateTrayMenu(tray) orelse {
                std.debug.print("[tray] SDL_CreateTrayMenu failed: {s}\n", .{c.SDL_GetError()});
                c.SDL_DestroyTray(tray);
                registry.forgetTray(io, req.id);
                return;
            };
            registry.attachTrayHandles(io, req.id, tray, menu);
        },

        .destroy_tray => |req| {
            if (registry.trayHandle(io, req.id)) |tray| c.SDL_DestroyTray(tray);
            // Unconditional, handle or not: a tray destroyed before the
            // main thread ever materialized it still has a record to drop.
            // `SDL_DestroyTray` frees the whole menu tree, so no entry is
            // torn down individually here -- `forgetTray` walks them
            // transitively for the same reason.
            registry.forgetTray(io, req.id);
        },

        .set_tooltip => |req| {
            const tray = registry.trayHandle(io, req.id) orelse return;
            var scratch: [TrayRegistry.max_tooltip_len + 1]u8 = undefined;
            var tip = req.tooltip;
            const tooltip_z = tip.cString(&scratch);
            c.SDL_SetTrayTooltip(tray, if (tooltip_z.len == 0) null else tooltip_z.ptr);
        },

        .insert_entry => |req| {
            const parent = registry.parentMenuFor(io, req.parent_id);
            const menu = resolveParentMenu(registry, io, req.parent_id, parent) orelse return;

            var scratch: [TrayRegistry.max_label_len + 1]u8 = undefined;
            var lbl = req.label;
            const label_z = lbl.cString(&scratch);

            // SDL's own convention: a null label is what makes an entry a
            // separator. There is no separator flag.
            const label_ptr: [*c]const u8 = if (req.kind == .separator) null else label_z.ptr;
            var flags: c.SDL_TrayEntryFlags = switch (req.kind) {
                .button, .separator => c.SDL_TRAYENTRY_BUTTON,
                .checkbox => c.SDL_TRAYENTRY_CHECKBOX,
                .submenu => c.SDL_TRAYENTRY_SUBMENU,
            };
            if (!req.enabled) flags |= c.SDL_TRAYENTRY_DISABLED;
            if (req.kind == .checkbox and req.checked) flags |= c.SDL_TRAYENTRY_CHECKED;

            const entry = c.SDL_InsertTrayEntryAt(menu, req.pos, label_ptr, flags) orelse {
                std.debug.print("[tray] SDL_InsertTrayEntryAt failed: {s}\n", .{c.SDL_GetError()});
                registry.forgetEntry(io, req.id);
                return;
            };
            registry.attachEntryHandle(io, req.id, entry);

            // A submenu entry gets its own menu immediately rather than
            // lazily: its children are queued right behind it in the same
            // FIFO, so deferring would just mean failing to resolve them
            // one op later.
            if (req.kind == .submenu) {
                if (c.SDL_CreateTraySubmenu(entry)) |submenu| {
                    registry.attachSubmenu(io, req.id, submenu);
                } else {
                    std.debug.print("[tray] SDL_CreateTraySubmenu failed: {s}\n", .{c.SDL_GetError()});
                }
            }

            // Separators are not clickable and a submenu entry opens its
            // submenu rather than firing, so neither is armed -- a callback
            // on either would deliver an event no guest could act on.
            if (req.kind == .button or req.kind == .checkbox) {
                if (registry.entryHandles(io, req.id)) |h| {
                    if (h.ctx) |ctx| c.SDL_SetTrayEntryCallback(entry, trayEntryCallback, ctx);
                }
            }
        },

        .remove_entry => |req| {
            if (registry.entryHandles(io, req.id)) |h| {
                if (h.handle) |entry| c.SDL_RemoveTrayEntry(entry);
            }
            registry.forgetEntry(io, req.id);
        },

        .set_entry_label => |req| {
            const h = registry.entryHandles(io, req.id) orelse return;
            const entry = h.handle orelse return;
            if (h.kind == .separator) return;
            var scratch: [TrayRegistry.max_label_len + 1]u8 = undefined;
            var lbl = req.label;
            c.SDL_SetTrayEntryLabel(entry, lbl.cString(&scratch).ptr);
        },

        .set_entry_checked => |req| {
            const h = registry.entryHandles(io, req.id) orelse return;
            const entry = h.handle orelse return;
            // SDL documents `SDL_SetTrayEntryChecked` as valid only for
            // checkboxes; calling it on a button is undefined rather than
            // ignored, so the kind is checked here rather than trusted.
            if (h.kind != .checkbox) return;
            c.SDL_SetTrayEntryChecked(entry, req.checked);
        },

        .set_entry_enabled => |req| {
            const h = registry.entryHandles(io, req.id) orelse return;
            const entry = h.handle orelse return;
            c.SDL_SetTrayEntryEnabled(entry, req.enabled);
        },
    }
}

/// Resolves the `*SDL_TrayMenu` an entry with this `parent_id` belongs in,
/// creating the parent's submenu first if it turns out not to exist yet.
/// Returns null when the parent itself failed to materialize -- the child is
/// then dropped from the registry too, since nothing will ever be able to
/// hold it.
fn resolveParentMenu(registry: *TrayRegistry, io: Io, parent_id: u32, parent: TrayRegistry.ParentMenu) ?*c.SDL_TrayMenu {
    if (parent.menu) |menu| return menu;
    if (parent.needs_submenu) {
        const parent_entry = parent.parent_entry orelse return null;
        const submenu = c.SDL_CreateTraySubmenu(parent_entry) orelse {
            std.debug.print("[tray] SDL_CreateTraySubmenu failed: {s}\n", .{c.SDL_GetError()});
            return null;
        };
        registry.attachSubmenu(io, parent_id, submenu);
        return submenu;
    }
    return null;
}

/// SDL invokes this on the main thread during event pumping, which is what
/// makes the `SDL_GetTrayEntryChecked` read below legal -- see this file's
/// header.
///
/// A checkbox's payload carries the state SDL *actually* holds after the
/// click, not what the guest last set: SDL flips a checkbox itself, with no
/// guest involvement, so this read is the only place the true value is
/// observable. It is written back to the registry's mirror in the same
/// breath, which is what lets `natyv_tray_entry_checked` answer later from
/// the worker thread without a main-thread round trip.
fn trayEntryCallback(userdata: ?*anyopaque, entry: ?*c.SDL_TrayEntry) callconv(.c) void {
    const ctx: *TrayRegistry.CallbackContext = @ptrCast(@alignCast(userdata orelse return));
    const env = callback_env orelse return;

    var buf: [32]u8 = undefined;
    var payload: []const u8 = "{}";
    if (entry) |e| {
        if (ctx.registry.entryHandles(env.io, ctx.entry_id)) |h| {
            if (h.kind == .checkbox) {
                const checked = c.SDL_GetTrayEntryChecked(e);
                ctx.registry.recordChecked(env.io, ctx.entry_id, checked);
                payload = std.fmt.bufPrint(&buf, "{{\"checked\":{}}}", .{checked}) catch "{}";
            }
        }
    }

    // surface_id 0: a tray entry belongs to no window and no floating
    // surface, the same "no particular surface" value `Dispatch`'s own
    // synthetic pushes already use.
    env.queue.push(env.io, ctx.entry_id, .click, payload, 0);
}
