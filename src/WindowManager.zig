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
//! Stage 3 scope: a hardcoded second window, created directly via
//! `createWindowContext` from main.zig's own dev-only scaffolding (no
//! guest-facing wire surface exists yet). The real guest-facing
//! `natyv_clay_create_window`/`natyv_destroy_window` host functions, their
//! bounded pending-request queue, and the async create/teardown flow the
//! multi-window plan describes are Stage 4 -- this file's `createWindowContext`/
//! `destroyWindowContext` are the synchronous, main-thread-only mechanics
//! Stage 4's queue-draining code will call into, not a replacement for the
//! queue itself.

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
    /// Set once (by an `SDL_EVENT_WINDOW_CLOSE_REQUESTED` for this window,
    /// or -- Stage 3 dev scaffolding, see `dev_close_button_id` below -- a
    /// click on this window's own hardcoded close button) and drained once
    /// per frame after that frame's drawing finishes: this window's own
    /// layout/text-sync/draw passes are skipped for the remainder of the
    /// frame they're set on, and the window is torn down right after. Never
    /// set for the original startup window (`root_widget_id == null`) --
    /// closing that one sets `running = false` instead, unconditional quit,
    /// same as today.
    pending_close: bool = false,
    /// Stage 3 dev-only scaffolding: the widget id of this window's own
    /// hardcoded "close this window" Button, if it has one -- deleted in
    /// Stage 4 once a real guest-facing close affordance (a guest-declared
    /// Button calling `natyv_destroy_window` itself) supersedes it. `null`
    /// for the original startup window, which has no such button.
    dev_close_button_id: ?u32 = null,
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
