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
const timing = @import("timing.zig");
const ClayLayout = @import("capabilities/ClayLayout.zig");
const InteractionState = @import("InteractionState.zig");
const DrawBatcher = @import("DrawBatcher.zig");
const WidgetHost = @import("widgets/WidgetHost.zig");
const ShapeCache = @import("capabilities/ShapeCache.zig");
const ImageCache = @import("capabilities/ImageCache.zig");

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
    /// Styling system Stage 3 (post-pivot): per-window cache of the
    /// anti-aliased circle/ring masks widgets like RadioButton draw through
    /// -- see ShapeCache.zig's own doc comment. Textures are
    /// renderer-scoped, so this can't be shared across windows.
    shape_cache: ShapeCache.Cache = .{},
    /// Texture-fill styling system: per-window cache of decoded background
    /// images -- see ImageCache.zig's own doc comment. Same renderer-scoped
    /// reasoning as `shape_cache`, kept as a separate cache since it's keyed
    /// by asset id rather than shape geometry.
    image_cache: ImageCache.Cache = .{},
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
    /// This window's own equivalent of `ClayLayout.last_computed_generation`
    /// -- the `WidgetHost.layout_generation` value as of this window's last
    /// real `SDL_RenderClear`/redraw/`SDL_RenderPresent` pass, `null` until
    /// the first one. `FrameLoop.drawWindow` compares against this (plus a
    /// couple of non-generation-tracked cases -- see its own doc comment) to
    /// skip that pass entirely on a frame where nothing for this window
    /// actually changed, rather than repainting unconditionally every wake.
    last_drawn_generation: ?u64 = null,
    /// Real, empirically-found necessity, not defensive paranoia: a
    /// brand-new SDL window's very first `SDL_RenderPresent` can land
    /// before the OS compositor has it fully mapped/visible -- confirmed
    /// live (a real click-through after adding the generation-based redraw
    /// gate above): the window's own late-created widgets (a "Delete
    /// Selected" button, pager buttons -- all real, all present in the
    /// registry, all drawn in that one real first pass, per a temporary
    /// debug print showing `draw_count` frozen at 1 forever) never actually
    /// appeared on screen, because nothing ever forced a *second* present
    /// to correct whatever the compositor did with the first one. Forces
    /// every real redraw to actually happen (bypassing the generation gate
    /// entirely) for `warmup_ms` after window creation -- cheap (a handful
    /// of extra real frames, once, per window) and matches common real
    /// game-engine/GUI-toolkit practice of not trusting a window's first
    /// frame(s) to actually display.
    created_at_ms: i64 = 0,
    /// Real, incremented-only-when-`drawWindow` actually redraws counter --
    /// exists purely so a test can assert the dirty-check above is actually
    /// skipping work (an unchanged, non-animating scene should draw once
    /// across N calls), the same role `ClayLayout.recompute_count` already
    /// plays one layer up.
    draw_count: usize = 0,
};

/// Creates a real second OS window: `SDL_Window` + `SDL_Renderer` + (when
/// `clay_enabled`) an owned `ClayLayout` sized to it + its own
/// renderer-backed `TTF_TextEngine`. Main-thread-only, same as every SDL/
/// Clay/TTF call this mirrors from `main.zig`'s own primary-window setup.
///
/// Real, user-driven resizing (2026-09-02): `SDL_WINDOW_RESIZABLE` applies
/// here, so every real OS window natyv ever creates -- the primary window
/// and any guest-created `<Window>` alike -- can be dragged by its edges,
/// not just the primary one. No other resize-specific code lives here:
/// `FrameLoop.layoutWindow` already queries the window's live current size
/// every frame regardless, and `ClayLayout.layoutIfNeeded`'s own dirty
/// check (`last_window_w`/`last_window_h`) is what actually notices a real
/// size change and re-lays-out against it.
pub fn createWindowContext(allocator: std.mem.Allocator, title: [:0]const u8, width: f32, height: f32, default_font: *c.TTF_Font, clay_enabled: bool, root_widget_id: ?u32) !WindowContext {
    const window = c.SDL_CreateWindow(title.ptr, @intFromFloat(width), @intFromFloat(height), c.SDL_WINDOW_RESIZABLE) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    const renderer: *c.SDL_Renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlRendererFailed;
    };
    errdefer c.SDL_DestroyRenderer(renderer);

    // Caps SDL_RenderPresent to the display's own refresh rate instead of
    // returning immediately -- confirmed via SDL3's own header that this
    // must run on the main thread, same as every other call in this
    // function. A `false` return (the driver doesn't support the requested
    // interval) is deliberately non-fatal -- an app is still fully usable
    // without vsync, just leaning more on main.zig's own SDL_WaitEventTimeout
    // to bound the frame loop's iteration rate instead.
    if (!c.SDL_SetRenderVSync(renderer, 1)) {
        std.debug.print("SDL_SetRenderVSync failed: {s}\n", .{c.SDL_GetError()});
    }

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
        .created_at_ms = timing.nowMs(),
    };
}

/// Tears down everything `createWindowContext` created, in the reverse
/// order it was created (same LIFO reasoning `main.zig`'s own `defer` chain
/// already relies on for the primary window -- the text engine must outlive
/// every `TTF_Text` created against it, so the caller must have already
/// destroyed this window's own widgets' text objects before calling this).
pub fn destroyWindowContext(self: *WindowContext, allocator: std.mem.Allocator) void {
    if (self.clay_layout) |*cl| cl.deinit(allocator);
    self.shape_cache.deinit();
    self.image_cache.deinit();
    c.TTF_DestroyRendererTextEngine(self.text_engine);
    c.SDL_DestroyRenderer(self.renderer);
    c.SDL_DestroyWindow(self.window);
}

test "texture fill: WindowContext's real image_cache/shape_cache decode and composite an image through a real SDL renderer, no error" {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInitFailed;
    defer c.SDL_Quit();
    const window = c.SDL_CreateWindow("windowmanager-texture-test", 64, 64, c.SDL_WINDOW_HIDDEN) orelse return error.SdlWindowFailed;
    defer c.SDL_DestroyWindow(window);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRendererFailed;
    defer c.SDL_DestroyRenderer(renderer);
    const text_engine = c.TTF_CreateRendererTextEngine(renderer) orelse return error.TextEngineFailed;
    defer c.TTF_DestroyRendererTextEngine(text_engine);

    // Built directly (not via createWindowContext) so this test needs no
    // real font -- createWindowContext requires one unconditionally even
    // with clay_enabled=false, since `default_font` is a non-optional
    // parameter regardless of whether ClayLayout.init ever actually reads
    // it. Every field this test cares about (image_cache/shape_cache) gets
    // its own real default, same as createWindowContext's own return value
    // would produce.
    var wctx = WindowContext{
        .window = window,
        .renderer = renderer,
        .clay_layout = null,
        .text_engine = text_engine,
        .root_widget_id = null,
    };

    const tex = ImageCache.getOrLoad(&wctx.image_cache, renderer, 1, &ImageCache.test_tga) orelse return error.DecodeFailed;
    try std.testing.expectEqual(@as(usize, 1), wctx.image_cache.count);

    // Real compositing pass through ShapeCache.drawRoundedRectTexture --
    // this is a genuine function *call* (not just a type reference), which
    // is what actually forces Zig to analyze that function's body and
    // ImageCache.getOrLoad's, per this file's own doc comment above on why
    // the earlier type-reference-only attempt reported 0 tests.
    ShapeCache.drawRoundedRectTexture(&wctx.shape_cache, renderer, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, .{ 4, 4, 4, 4 }, tex);
    try std.testing.expectEqualStrings("", std.mem.span(c.SDL_GetError()));

    wctx.shape_cache.deinit();
    wctx.image_cache.deinit();
}
