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
const ShapeShader = @import("capabilities/ShapeShader.zig");

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
    /// Styling system Stage 1: `null` means this window is on the Tier 1
    /// (feathered tessellation, not yet built) fallback path -- either no
    /// shared `ShapeShader.GpuState` was available process-wide (software
    /// renderer, or no GPU device on this machine), or this specific
    /// window's own `SDL_CreateGPURenderState` call failed. No widget's
    /// draw path reads this yet.
    shape_render: ?ShapeShader.WindowRenderState,
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
///
/// Styling system Stage 1: `shared_gpu` is `main.zig`'s single process-wide
/// `ShapeShader.GpuState` (or `null` if none could be created). When
/// present, tries `SDL_CreateGPURenderer` against that shared device first
/// -- every window shares one `SDL_GPUShader`, only the renderer-scoped
/// `SDL_GPURenderState` is per-window (see ShapeShader.zig's own doc
/// comment on why this differs from the original single-window prototype's
/// `SDL_CreateRenderer(window, SDL_GPU_RENDERER)`, which would silently
/// create a *new*, unshared device per window). Falls back to the plain
/// `SDL_CreateRenderer(window, null)` renderer (Tier 1, not yet built) if
/// `shared_gpu` is `null`, if `SDL_CreateGPURenderer` itself fails, or if
/// this window's own `SDL_CreateGPURenderState` fails -- a real, expected
/// outcome on some devices, not treated as fatal.
pub fn createWindowContext(allocator: std.mem.Allocator, title: [:0]const u8, width: f32, height: f32, default_font: *c.TTF_Font, clay_enabled: bool, root_widget_id: ?u32, shared_gpu: ?*const ShapeShader.GpuState) !WindowContext {
    const window = c.SDL_CreateWindow(title.ptr, @intFromFloat(width), @intFromFloat(height), 0) orelse {
        std.debug.print("SDL_CreateWindow failed: {s}\n", .{c.SDL_GetError()});
        return error.SdlWindowFailed;
    };
    errdefer c.SDL_DestroyWindow(window);

    var renderer: *c.SDL_Renderer = undefined;
    if (shared_gpu) |gpu| {
        renderer = c.SDL_CreateGPURenderer(gpu.device, window) orelse blk: {
            std.debug.print("[WindowManager] SDL_CreateGPURenderer failed ({s}), falling back to Tier 1\n", .{c.SDL_GetError()});
            break :blk c.SDL_CreateRenderer(window, null) orelse {
                std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
                return error.SdlRendererFailed;
            };
        };
    } else {
        renderer = c.SDL_CreateRenderer(window, null) orelse {
            std.debug.print("SDL_CreateRenderer failed: {s}\n", .{c.SDL_GetError()});
            return error.SdlRendererFailed;
        };
    }
    errdefer c.SDL_DestroyRenderer(renderer);

    const shape_render: ?ShapeShader.WindowRenderState = if (shared_gpu) |gpu| ShapeShader.createForWindow(gpu, renderer) else null;
    errdefer if (shape_render) |*sr| ShapeShader.destroyForWindow(@constCast(sr));

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
        .shape_render = shape_render,
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
    if (self.shape_render) |*sr| ShapeShader.destroyForWindow(sr);
    c.TTF_DestroyRendererTextEngine(self.text_engine);
    c.SDL_DestroyRenderer(self.renderer);
    c.SDL_DestroyWindow(self.window);
}
