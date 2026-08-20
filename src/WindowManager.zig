//! Multi-window Stage 3: owns the real OS resources behind each open native
//! window -- `SDL_Window`/`SDL_Renderer`/an owned `ClayLayout`/a per-window
//! `TTF_TextEngine` (text engines are renderer-specific, see F3's own doc
//! comment on `main.zig`'s original single engine) -- plus that window's own
//! per-frame interaction/draw-batching state. Kept outside `WidgetHost` (the
//! `Io.Mutex`-protected registry the worker thread touches concurrently)
//! since SDL/Clay/TTF resource creation and use is main-thread-only.
//!
//! `root_widget_id` is what ties a `WindowContext` back to the registry: the
//! `Slot.id` of that window's own `ClayStyle.window_root` marker widget, or
//! `null` for the original startup window (which has no such marker -- it
//! predates window_root entirely, and its own top-level content is just
//! ordinary `parent_id == null` widgets, exactly as before this feature
//! existed). `FloatingOrder.windowSubset` is the query that turns this id
//! into "which widgets belong to this window."
//!
//! Multi-window Stage 4: `createWindowContext`/`destroyWindowContext` are
//! the synchronous, main-thread-only mechanics -- `main.zig`'s frame loop
//! calls into them once per frame while draining `WidgetHost`'s own
//! `pending_window_requests`/`pending_window_teardowns` queues (see those
//! fields' own doc comments for the guest-facing `natyv_clay_create_window`/
//! `natyv_destroy_window` host functions that populate them).

const std = @import("std");
const c = @import("c.zig").c;
const ClayLayout = @import("capabilities/ClayLayout.zig");
const InteractionState = @import("InteractionState.zig");
const DrawBatcher = @import("DrawBatcher.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");

/// Small fixed cap, same "bump later if a real need shows up" precedent
/// `WidgetHost.max_widgets` itself already set.
pub const max_open_windows = 8;

pub const WindowContext = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    /// `null` when the Clay backend isn't enabled -- matches
    /// `main.zig`'s own `maybe_clay_layout` semantics, "a capability you
    /// didn't declare costs you nothing."
    clay_layout: ?ClayLayout,
    text_engine: *c.TTF_TextEngine,
    /// See file doc comment -- `null` for the original startup window.
    root_widget_id: ?u32,
    interaction: InteractionState = .{},
    draw_batcher: DrawBatcher = .{},
    /// Scratch hand-off from this window's own `layoutIfNeeded` call (early
    /// in the frame) to the `.scroll` event-pushing pass (later, once a
    /// fresh post-text-sync snapshot exists to resolve each id's
    /// surface_id) -- same "stash on the per-window context, not a bare
    /// frame-loop local" reasoning `interaction`/`draw_batcher` already
    /// establish.
    scrolled_ids: [WidgetHost.max_widgets]u32 = undefined,
    scrolled_count: usize = 0,
};

/// Creates a real second OS window: `SDL_Window` + `SDL_Renderer` + (when
/// `clay_enabled`) an owned `ClayLayout` sized to it + its own
/// renderer-backed `TTF_TextEngine`. Main-thread-only, same as every SDL/
/// Clay/TTF call this mirrors from `main.zig`'s own primary-window setup.
pub fn createWindowContext(allocator: std.mem.Allocator, title: [:0]const u8, width: f32, height: f32, default_font: *c.TTF_Font, clay_enabled: bool, root_widget_id: ?u32) !WindowContext {
    const window = c.SDL_CreateWindow(title.ptr, @intFromFloat(width), @intFromFloat(height), 0) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlRendererFailed;
    };
    errdefer c.SDL_DestroyRenderer(renderer);

    const text_engine = c.TTF_CreateRendererTextEngine(renderer) orelse {
        std.debug.print("TTF_CreateRendererTextEngine failed: {s}\n", .{c.SDL_GetError()});
        return error.TextEngineFailed;
    };
    errdefer c.TTF_DestroyRendererTextEngine(text_engine);

    const clay_layout: ?ClayLayout = if (clay_enabled) try ClayLayout.init(allocator, width, height, default_font) else null;

    return .{
        .window = window,
        .renderer = renderer,
        .clay_layout = clay_layout,
        .text_engine = text_engine,
        .root_widget_id = root_widget_id,
    };
}

/// Tears down everything `createWindowContext` created, in the reverse
/// order it was created (same LIFO reasoning `main.zig`'s own `defer` chain
/// already relies on for the primary window -- the text engine must outlive
/// every `TTF_Text` created against it, so the caller must have already
/// destroyed this window's own widgets' text objects before calling this).
pub fn destroyWindowContext(self: *WindowContext, allocator: std.mem.Allocator) void {
    if (self.clay_layout) |*cl| cl.deinit(allocator);
    c.TTF_DestroyRendererTextEngine(self.text_engine);
    c.SDL_DestroyRenderer(self.renderer);
    c.SDL_DestroyWindow(self.window);
}
